#if canImport(Network)
import Foundation
import Network
import Testing
import HeidrunCore
@testable import HeidrunNIOClient

/// The NIO client against a fake classic Hotline server: the transfer
/// port ships a two-fork FILP envelope, and only the data fork may
/// reach the destination file.
@Suite("NIO single-file download — classic FILP envelope")
struct NIODownloadEnvelopeIntegrationTests {

    @Test("downloadFile writes only the data fork of a classic envelope")
    func downloadUnwrapsEnvelope() async throws {
        let (control, transfer) = try await LoopbackServer.startWithTransferPort()
        defer { control.stop(); transfer.stop() }

        let payload = Data((0..<100_000).map { UInt8(($0 * 7) & 0xFF) })
        let envelope = classicEnvelope(name: "sin_icons.gz", type: "SIT!", creator: "SITx", data: payload)

        async let serverSide: Void = {
            let conn = try await control.acceptHandshake()
            let login = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: login.header.taskNumber)
            let request = try await conn.readPacket()
            #expect(request.header.transactionID == 202)
            try await conn.sendReply(
                transactionID: 202,
                taskNumber: request.header.taskNumber,
                fields: [
                    .uint32(.transferID, 5),
                    .uint32(.transferSize, UInt32(envelope.count)),
                    .uint32(.fileSize, UInt32(payload.count))
                ]
            )
            let side = try await transfer.acceptNextConnection()
            _ = try await side.receiveExactly(16)
            try await side.sendAsync(envelope)
        }()

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("nio-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: control.port)
        )
        try await client.login(name: "", password: "", nickname: "probe", icon: 1, emoji: nil)
        try await client.downloadFile(at: RemotePath(components: []), name: "sin_icons.gz", to: destination)
        try await serverSide
        await client.disconnect()

        #expect(try Data(contentsOf: destination) == payload)
    }
}
#endif
