#if canImport(Network)
import Foundation
import Network
import Testing
@testable import HeidrunCore

/// Classic servers (hxd, MacDomain) read exactly one 16-byte HTXF
/// preamble and then expect `FILP`. A second preamble on the upload
/// side channel is parsed as the FILP header and the upload stalls
/// at 0 bytes.
@Suite("Single-file upload — one HTXF handshake")
struct FileUploadHandshakeIntegrationTests {

    @Test("upload sends one handshake carrying the envelope size, then FILP")
    func uploadSendsSingleHandshake() async throws {
        let (control, transfer) = try await MiniHotlineServer.startWithTransferPort()
        defer { control.stop(); transfer.stop() }

        let fileName = "Heidrun.dmg"
        let payload = Data((0..<70_000).map { UInt8($0 & 0xFF) })
        let envelopeSize = UploadFraming.totalSize(
            nameLength: fileName.utf8.count,
            dataLength: UInt64(payload.count),
            resourceLength: 0
        )

        async let serverSide: (handshake: Data, body: Data) = {
            let conn = try await control.acceptHandshake()
            let login = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: login.header.taskNumber, fields: [])
            let request = try await conn.readPacket()
            #expect(request.header.transactionID == 203)
            try await conn.sendReply(
                transactionID: 203,
                taskNumber: request.header.taskNumber,
                fields: [.uint32(.transferID, 42)]
            )
            let side = try await transfer.acceptNextConnection()
            let handshake = try await side.receiveExactly(16)
            let body = try await side.receiveExactly(Int(envelopeSize))
            return (handshake, body)
        }()

        let client = try await HotlineNetworkClient.connect(
            settings: .init(name: "t", address: "127.0.0.1", port: control.port)
        )
        try await client.login(name: "", password: "", nickname: "probe", icon: 1, emoji: nil)
        let handle = try await client.startUpload(
            at: RemotePath(components: []), name: fileName, size: UInt64(payload.count), resume: false
        )
        try await client.sendUpload(
            payload,
            for: handle,
            fileName: fileName,
            type: "BINA",
            creator: "dosa",
            creationDate: Date(),
            modificationDate: Date(),
            resourceFork: Data(),
            progress: nil
        )
        let (handshake, body) = try await serverSide
        let expectedHandshake = TransferHandshake.encode(transferID: 42, transferSize: UInt32(envelopeSize))
        #expect(handshake == expectedHandshake)
        #expect(body.prefix(4) == Data("FILP".utf8))
        await client.disconnect()
    }
}
#endif
