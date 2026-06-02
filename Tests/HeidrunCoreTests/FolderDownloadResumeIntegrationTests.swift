#if canImport(Network)
import Foundation
import Network
import Testing
@testable import HeidrunCore

/// Drives the live `FolderDownloadDecoder` over a real loopback TCP pair
/// and verifies the resume path puts the right bytes on the wire and
/// reports `dataForkOffset` back through the yielded items.
@Suite("FolderDownloadDecoder resume — loopback")
struct FolderDownloadResumeIntegrationTests {

    @Test("client ACKs resume vs fresh files and decodes offset back")
    func resumeRoundTrip() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.transfer.client")
        let clientConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        try await clientConnection.startAndWaitForReady(on: clientQueue)
        let serverConn = try await acceptedConnection

        let actor = FileTransferActor(
            connection: clientConnection,
            queue: clientQueue,
            transferID: 1,
            totalSize: 0
        )

        // Resume map: only "alpha.txt" has an existing partial copy.
        let resumeOffset: UInt32 = 0x0000_1000
        let resumeProvider: FolderDownloadResumeProvider = { components in
            if components == ["alpha.txt"] {
                return ResumeInfo(dataForkOffset: resumeOffset, resourceForkOffset: 0)
            }
            return nil
        }

        let alphaTail = Data([0xAA, 0xAA, 0xAA, 0xAA])    // bytes after offset
        let betaFull  = Data([0xBB, 0xBB, 0xBB, 0xBB, 0xBB])

        async let serverWork: Void = playFolderTape(
            on: serverConn,
            files: [
                .init(name: "alpha.txt", data: alphaTail, expectedAction: .resume(offset: resumeOffset)),
                .init(name: "beta.txt", data: betaFull, expectedAction: .download)
            ]
        )

        let (stream, continuation) = AsyncThrowingStream<FolderDownloadItem, Error>.makeStream()
        async let driveDone: Void = FolderDownloadDecoder.drive(
            actor: actor,
            encoding: .macOSRoman,
            resumeProvider: resumeProvider,
            continuation: continuation
        )

        var items: [FolderDownloadItem] = []
        let collector = Task {
            for try await item in stream {
                items.append(item)
            }
            return items
        }

        await driveDone
        continuation.finish()
        try await serverWork
        let collected = try await collector.value

        #expect(collected.count == 2)
        #expect(collected[0].relativePath == ["alpha.txt"])
        #expect(collected[0].dataForkOffset == resumeOffset)
        #expect(collected[0].data == alphaTail)
        #expect(collected[1].relativePath == ["beta.txt"])
        #expect(collected[1].dataForkOffset == 0)
        #expect(collected[1].data == betaFull)

        await actor.cancel()
        serverConn.cancel()
    }

    @Test("yielded items expose the per-item MACR resource fork bytes")
    func resourceForkSurfaced() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.transfer.client.rsrc")
        let clientConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        try await clientConnection.startAndWaitForReady(on: clientQueue)
        let serverConn = try await acceptedConnection

        let actor = FileTransferActor(
            connection: clientConnection,
            queue: clientQueue,
            transferID: 1,
            totalSize: 0
        )

        let dataFork = Data([0x01, 0x02, 0x03, 0x04])
        let resourceFork = Data((0..<64).map { UInt8(($0 * 3 + 7) & 0xFF) })

        async let serverWork: Void = playFolderTape(
            on: serverConn,
            files: [
                .init(
                    name: "icon.icns",
                    data: dataFork,
                    expectedAction: .download,
                    resourceFork: resourceFork
                )
            ]
        )

        let (stream, continuation) = AsyncThrowingStream<FolderDownloadItem, Error>.makeStream()
        async let driveDone: Void = FolderDownloadDecoder.drive(
            actor: actor,
            encoding: .macOSRoman,
            resumeProvider: nil,
            continuation: continuation
        )

        var items: [FolderDownloadItem] = []
        let collector = Task {
            for try await item in stream {
                items.append(item)
            }
            return items
        }

        await driveDone
        continuation.finish()
        try await serverWork
        let collected = try await collector.value

        #expect(collected.count == 1)
        #expect(collected[0].data == dataFork)
        #expect(collected[0].resourceFork == resourceFork)

        await actor.cancel()
        serverConn.cancel()
    }

    // MARK: - Tape helpers

    private struct TapeFile {
        let name: String
        let data: Data
        let expectedAction: ExpectedAction
        var resourceFork: Data = Data()
    }

    private enum ExpectedAction {
        case download
        case resume(offset: UInt32)
    }

    /// Play the server side of a folder download for one or more files,
    /// confirming the client's per-item action ACK along the way. Sends
    /// the UInt16 0 sentinel at the end.
    private func playFolderTape(
        on connection: NWConnection,
        files: [TapeFile]
    ) async throws {
        for file in files {
            try await sendItemHeader(connection, name: file.name)
            try await expectActionAck(connection, expected: file.expectedAction)
            try await sendFileBody(
                connection,
                name: file.name,
                data: file.data,
                resourceFork: file.resourceFork
            )
        }
        var end = Data()
        end.appendBigEndian(UInt16(0))
        try await connection.sendAsync(end)
    }

    private func sendItemHeader(_ connection: NWConnection, name: String) async throws {
        let nameBytes = name.data(using: .macOSRoman) ?? Data()
        var header = Data()
        header.appendBigEndian(UInt16(0))                 // folderType = 0 (file)
        header.appendBigEndian(UInt16(1))                 // 1 component
        header.appendBigEndian(UInt16(0))                 // pad
        header.append(UInt8(nameBytes.count))             // name length
        header.append(nameBytes)

        var frame = Data()
        frame.appendBigEndian(UInt16(header.count))
        frame.append(header)
        try await connection.sendAsync(frame)
    }

    private func expectActionAck(_ connection: NWConnection, expected: ExpectedAction) async throws {
        let actionBytes = try await connection.receiveExactly(2)
        var cursor = ByteCursor(data: actionBytes)
        let action: UInt16 = cursor.readBigEndian()

        switch expected {
        case .download:
            #expect(action == 1)
        case .resume(let offset):
            #expect(action == 2)
            let blob = try await connection.receiveExactly(ResumeInfoCodec.byteCount)
            let info = ResumeInfoCodec.decode(blob)
            #expect(info?.dataForkOffset == offset)
        }
    }

    /// Build and send the per-file framing the decoder expects:
    /// itemFileSize + FILP + INFO + DATA + MACR + forks.
    private func sendFileBody(
        _ connection: NWConnection,
        name: String,
        data: Data,
        resourceFork: Data = Data()
    ) async throws {
        let info = buildInfoBlock(name: name)
        var filp = Data()
        filp.append(contentsOf: [0x46, 0x49, 0x4C, 0x50])     // "FILP"
        filp.append(Data(repeating: 0, count: 32))
        filp.appendBigEndian(UInt32(info.count))              // infoLength at offset 36

        var dataHeader = Data()
        dataHeader.append(contentsOf: [0x44, 0x41, 0x54, 0x41])  // "DATA"
        dataHeader.append(Data(repeating: 0, count: 8))
        dataHeader.appendBigEndian(UInt32(data.count))           // length at offset 12

        var macrHeader = Data()
        macrHeader.append(contentsOf: [0x4D, 0x41, 0x43, 0x52])  // "MACR"
        macrHeader.append(Data(repeating: 0, count: 8))
        macrHeader.appendBigEndian(UInt32(resourceFork.count))   // resource fork length

        var body = Data()
        body.appendBigEndian(UInt32(data.count))   // itemFileSize (informational)
        body.append(filp)
        body.append(info)
        body.append(dataHeader)
        body.append(data)
        body.append(macrHeader)
        body.append(resourceFork)
        try await connection.sendAsync(body)
    }

    private func buildInfoBlock(name: String) -> Data {
        var info = Data()
        info.append(contentsOf: [0x41, 0x4D, 0x41, 0x43])     // "AMAC"
        info.appendBigEndian(UInt32(0x54455854))              // type "TEXT"
        info.appendBigEndian(UInt32(0x3F3F3F3F))              // creator "????"
        info.append(Data(repeating: 0, count: 4))
        info.appendBigEndian(UInt32(256))
        info.append(Data(repeating: 0, count: 32))
        info.appendBigEndian(UInt16(1904))                    // creation base year
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(UInt32(0))                       // creation seconds
        info.appendBigEndian(UInt16(1904))                    // mod base year
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(UInt32(0))                       // mod seconds
        info.append(Data(repeating: 0, count: 2))             // reserved
        let nameBytes = name.data(using: .macOSRoman) ?? Data()
        info.appendBigEndian(UInt16(nameBytes.count))
        info.append(nameBytes)
        info.appendBigEndian(UInt16(0))                       // empty comment
        return info
    }
}
#endif
