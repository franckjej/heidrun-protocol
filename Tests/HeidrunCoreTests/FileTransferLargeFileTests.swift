#if canImport(Network)
import Foundation
import Network
import Testing
@testable import HeidrunCore

/// Phase B large-file transfer behaviours on the Network.framework path:
/// the 24-byte HTXF handshake, the 64-bit upload-size request field, and
/// the raw-data (no FILP/INFO/DATA/MACR) upload body for files > 4 GiB.
@Suite("FileTransferActor — large files")
struct FileTransferLargeFileTests {

    @Test("uploadRequestFields appends xferSize64 only in large-file mode")
    func uploadRequestFieldsLargeFile() {
        let hugeSize: UInt64 = 0x1_2345_6789
        let largeFields = HotlineNetworkClient.uploadRequestFields(
            path: RemotePath(),
            name: "huge.bin",
            size: hugeSize,
            resume: false,
            largeFile: true,
            encoding: .macOSRoman
        )
        #expect(largeFields.uint64(.xferSize64) == hugeSize)
        // Legacy field is clamped to 32 bits.
        #expect(largeFields.uint32(.transferSize) == 0xFFFF_FFFF)
    }

    @Test("uploadRequestFields omits xferSize64 on the legacy path")
    func uploadRequestFieldsLegacy() {
        let smallFields = HotlineNetworkClient.uploadRequestFields(
            path: RemotePath(),
            name: "small.txt",
            size: 1234,
            resume: false,
            largeFile: false,
            encoding: .macOSRoman
        )
        #expect(smallFields.uint64(.xferSize64) == nil)
        #expect(smallFields.uint32(.transferSize) == 1234)
    }

    /// Mirrors `sendUpload`'s large-file body path: a 24-byte handshake
    /// followed by raw data-fork bytes, no FILP/INFO/DATA/MACR envelope.
    @Test("large-file upload sends a 24-byte preamble + raw body (no FFO magic)")
    func largeFileUploadRawBody() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.largeFile.upload")
        let clientConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        try await clientConnection.startAndWaitForReady(on: clientQueue)
        let serverConn = try await acceptedConnection

        // Announce a >4 GiB transfer; the actual test payload is small.
        let announcedSize: UInt64 = 0x1_0000_0010
        let actor = FileTransferActor(
            connection: clientConnection,
            queue: clientQueue,
            transferID: 0x11223344,
            totalSize: announcedSize,
            isLargeFile: true
        )

        let body = Data((0..<512).map { UInt8($0 & 0xFF) })
        let expectedCount = TransferHandshake.largeFileByteCount + body.count

        async let received: Data = serverConn.receiveExactly(expectedCount)

        try await actor.sendHandshake()
        try await actor.sendBytes(body)
        try await actor.finishUpload()

        let bytes = try await received
        #expect(bytes.count == expectedCount)

        let preamble = bytes.prefix(TransferHandshake.largeFileByteCount)
        let parsed = TransferHandshake.parse(Data(preamble))
        #expect(parsed?.isLargeFile == true)
        #expect(parsed?.size == announcedSize)

        // The body is raw: no FILP/DATA four-CC envelope magic anywhere.
        let filp = Data("FILP".utf8)
        let dataMagic = Data("DATA".utf8)
        let payload = Data(bytes.suffix(body.count))
        #expect(payload == body)
        #expect(bytes.range(of: filp) == nil)
        #expect(bytes.range(of: dataMagic) == nil)

        serverConn.cancel()
    }
}
#endif
