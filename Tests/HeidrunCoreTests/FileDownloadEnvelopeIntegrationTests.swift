#if canImport(Network)
import Foundation
import Network
import Testing
@testable import HeidrunCore

/// Drives a real `HotlineNetworkClient` against a fake classic Hotline
/// server: no 0xE002 echo on login, a TX 202 reply whose 64-bit transfer
/// size wrongly carries the file size (as Hotline Central Hub does), and
/// a two-fork FILP envelope on the transfer port.
@Suite("Single-file download — classic FILP envelope")
struct FileDownloadEnvelopeIntegrationTests {

    private func serveDownload(
        control: MiniHotlineServer,
        transfer: MiniHotlineServer,
        envelope: Data,
        fileSize: UInt64
    ) async throws {
        let conn = try await control.acceptHandshake()
        let login = try await conn.readPacket()
        #expect(login.header.transactionID == 107)
        try await conn.sendReply(
            transactionID: 107,
            taskNumber: login.header.taskNumber,
            fields: [.uint16(.clientVersion, 200), .uint16(.capabilities, 1)]
        )
        let request = try await conn.readPacket()
        #expect(request.header.transactionID == 202)
        try await conn.sendReply(
            transactionID: 202,
            taskNumber: request.header.taskNumber,
            fields: [
                .uint32(.transferID, 77),
                .uint32(.transferSize, UInt32(envelope.count)),
                .uint32(.fileSize, UInt32(fileSize)),
                .uint64(.fileSize64, fileSize),
                .uint64(.xferSize64, fileSize)        // the misreport: file size, not wire size
            ]
        )
        let side = try await transfer.acceptNextConnection()
        let handshake = try await side.receiveExactly(16)
        #expect(handshake.prefix(4) == Data("HTXF".utf8))
        try await side.sendAsync(envelope)
    }

    @Test("downloadStream yields only the data fork of a classic envelope")
    func freshDownloadUnwrapsEnvelope() async throws {
        let (control, transfer) = try await MiniHotlineServer.startWithTransferPort()
        defer { control.stop(); transfer.stop() }

        let payload = Data((0..<100_000).map { UInt8($0 & 0xFF) })
        let envelope = classicEnvelope(name: "Icons 2014.zip", type: "ZIP ", creator: "SITx", data: payload)
        async let serverSide: Void = serveDownload(
            control: control, transfer: transfer, envelope: envelope, fileSize: UInt64(payload.count)
        )

        let client = try await HotlineNetworkClient.connect(
            settings: .init(name: "t", address: "127.0.0.1", port: control.port)
        )
        try await client.login(name: "", password: "", nickname: "probe", icon: 1, emoji: nil)
        let handle = try await client.startDownload(
            at: RemotePath(components: []), name: "Icons 2014.zip", dataForkOffset: 0, resourceForkOffset: 0
        )
        var received = Data()
        for try await chunk in client.downloadStream(for: handle) {
            received.append(chunk)
        }
        try await serverSide
        #expect(received == payload)
        await client.disconnect()
    }

    @Test("a resumed download unwraps the resumed envelope's remainder")
    func resumedDownloadUnwrapsEnvelope() async throws {
        let (control, transfer) = try await MiniHotlineServer.startWithTransferPort()
        defer { control.stop(); transfer.stop() }

        let tail = Data("klmnopqrstuvwxyz".utf8)
        let envelope = classicEnvelope(name: "alphabet.txt", type: "TEXT", creator: "ttxt", data: tail)
        async let serverSide: Void = serveDownload(
            control: control, transfer: transfer, envelope: envelope, fileSize: 26
        )

        let client = try await HotlineNetworkClient.connect(
            settings: .init(name: "t", address: "127.0.0.1", port: control.port)
        )
        try await client.login(name: "", password: "", nickname: "probe", icon: 1, emoji: nil)
        let handle = try await client.startDownload(
            at: RemotePath(components: []), name: "alphabet.txt", dataForkOffset: 10, resourceForkOffset: 0
        )
        var received = Data()
        for try await chunk in client.downloadStream(for: handle) {
            received.append(chunk)
        }
        try await serverSide
        #expect(received == tail)
        await client.disconnect()
    }
}
#endif
