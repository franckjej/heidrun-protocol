import Foundation
import Testing
import HeidrunCore
import HeidrunTestServerKit

/// End-to-end tests pairing the real `HotlineNetworkClient` with the
/// `TestServerInstance`. They exercise listFiles + the HTXF side
/// channel (download + upload), including resume.
@Suite("HotlineNetworkClient ↔ TestServerInstance — file transfers")
struct FileTransferIntegrationTests {

    @Test("listFiles returns the seeded VFS")
    func listFilesRoundtrip() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }

        let client = try await loggedInClient(controlPort: server.controlPort)
        defer { Task { await client.disconnect() } }

        let listing = try await client.listFiles(at: [])
        let names = Set(listing.map(\.name))
        #expect(names.contains("README.txt"))
        #expect(names.contains("lipsum.bin"))
        #expect(names.contains("Development Builds"))
    }

    @Test("createFolder + listFiles + delete round-trip")
    func createDeleteRoundtrip() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }
        let client = try await loggedInClient(controlPort: server.controlPort)
        defer { Task { await client.disconnect() } }

        try await client.createFolder(at: [], name: "Inbox")
        let listingAfterCreate = try await client.listFiles(at: [])
        #expect(listingAfterCreate.contains(where: { $0.name == "Inbox" && $0.isFolder }))

        try await client.deleteEntry(at: [], name: "Inbox")
        let listingAfterDelete = try await client.listFiles(at: [])
        #expect(!listingAfterDelete.contains(where: { $0.name == "Inbox" }))
    }

    @Test("download streams the file's bytes from the side channel")
    func downloadFile() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }
        let client = try await loggedInClient(controlPort: server.controlPort)
        defer { Task { await client.disconnect() } }

        let handle = try await client.startDownload(
            at: [],
            name: "lipsum.bin",
            dataForkOffset: 0,
            resourceForkOffset: 0
        )

        var collected = Data()
        for try await chunk in client.downloadStream(for: handle) {
            collected.append(chunk)
        }

        // The fixture is 4096 bytes of [0, 1, 2, ... ] mod 256.
        let expected = Data((0..<4096).map { UInt8($0 & 0xFF) })
        #expect(collected == expected)
        #expect(UInt64(collected.count) == handle.totalSize)
    }

    @Test("download with dataForkOffset > 0 resumes from the requested byte")
    func downloadResume() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }
        let client = try await loggedInClient(controlPort: server.controlPort)
        defer { Task { await client.disconnect() } }

        let offset: UInt32 = 1024
        let handle = try await client.startDownload(
            at: [],
            name: "lipsum.bin",
            dataForkOffset: offset,
            resourceForkOffset: 0
        )
        // Server reports the *remaining* bytes in the transferSize field.
        #expect(handle.totalSize == UInt64(4096 - offset))

        var collected = Data()
        for try await chunk in client.downloadStream(for: handle) {
            collected.append(chunk)
        }
        let expectedTail = Data((Int(offset)..<4096).map { UInt8($0 & 0xFF) })
        #expect(collected == expectedTail)
    }

    @Test("upload pushes the data fork into the VFS")
    func uploadFile() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }
        let client = try await loggedInClient(controlPort: server.controlPort)
        defer { Task { await client.disconnect() } }

        let payload = Data((0..<2048).map { UInt8(($0 * 7) & 0xFF) })
        let handle = try await client.startUpload(
            at: [],
            name: "uploaded.bin",
            size: UInt32(payload.count),
            resume: false
        )
        try await client.sendUpload(
            payload,
            for: handle,
            fileName: "uploaded.bin",
            progress: nil
        )

        // Give the side-channel handler a moment to commit to the VFS.
        try await waitFor {
            await server.state.vfs.bytes(at: [], name: "uploaded.bin") != nil
        }
        let stored = await server.state.vfs.bytes(at: [], name: "uploaded.bin")
        #expect(stored == payload)

        // And the new entry shows up in listFiles.
        let listing = try await client.listFiles(at: [])
        #expect(listing.contains(where: { $0.name == "uploaded.bin" }))
    }

    @Test("fetchFileInfo returns the seeded type/dates")
    func fetchFileInfo() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }
        let client = try await loggedInClient(controlPort: server.controlPort)
        defer { Task { await client.disconnect() } }

        let info = try await client.fetchFileInfo(at: [], name: "README.txt")
        #expect(info.file.name == "README.txt")
        #expect(info.file.type.stringValue == "TEXT")
        #expect(info.dataForkSize > 0)
    }

    // MARK: - Helpers

    private func loggedInClient(controlPort: UInt16) async throws -> HotlineNetworkClient {
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: controlPort
            )
        )
        try await client.login(name: "guest", password: "", nickname: "Tester", icon: 1)
        return client
    }

    private func waitFor(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitFor timed out")
    }
}
