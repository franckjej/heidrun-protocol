#if canImport(Network)
import Foundation
import Network
import Testing
@testable import HeidrunCore

/// Regression tests for the upload tear-down race. The original
/// `finishUpload()` ended a transfer by calling `connection.cancel()`,
/// which is `NWConnection`'s abort path — it discards anything still
/// queued in the framework's send pipeline. For small final writes
/// (data-fork-only uploads send a 16-byte MACR trailer) the bytes were
/// in the first TCP segment and beat cancel; for real resource forks
/// (hundreds of KB), the rsrc was still in `NWConnection`'s queue when
/// cancel ran and never reached the server. The fix folds the trailer
/// into a send with `isComplete: true` so the kernel drains the queue
/// before the connection closes.
///
/// Note: these tests run on same-process loopback, where the kernel
/// accepts the whole payload before `cancel()` runs and the bug
/// doesn't reproduce. They cover the new API surface and catch any
/// future regression that drops bytes outright; the real-network
/// truncation case is verified by the rc15 upload smoke test against a
/// remote server (see CHANGELOG entry for v1.0.0-rc15).
@Suite("FileTransferActor upload — graceful close")
struct FileTransferActorUploadTests {

    @Test("finishUpload delivers a large final payload in full")
    func finishUploadDeliversLargePayload() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.upload.client")
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
            transferID: 0xDEADBEEF,
            totalSize: 0
        )

        // 256 KB final payload — large enough that NWConnection's send
        // queue can't fully drain before a synchronous `cancel()` runs.
        // The pre-fix code would lose almost all of these bytes.
        let prefix = Data((0..<32).map { UInt8($0) })
        var finalBytes = [UInt8]()
        finalBytes.reserveCapacity(256 * 1024)
        for i in 0..<(256 * 1024) {
            finalBytes.append(UInt8((i &* 31 &+ 7) & 0xFF))
        }
        let finalPayload = Data(finalBytes)
        let expectedSize = 16 /* HTXF handshake */ + prefix.count + finalPayload.count

        // Server side: read exactly the bytes we expect. With the buggy
        // code, this never completes because cancel() discarded the
        // payload before it left the framework. With the fix, the bytes
        // arrive in order and the read returns.
        async let received: Data = serverConn.receiveExactly(expectedSize)

        try await actor.sendHandshake(transferSize: UInt32(prefix.count + finalPayload.count))
        try await actor.sendBytes(prefix)
        try await actor.finishUpload(finalPayload)

        let bytes = try await received
        #expect(bytes.count == expectedSize)
        #expect(bytes.suffix(finalPayload.count) == finalPayload)

        serverConn.cancel()
    }

    @Test("large-file download sends the 24-byte handshake parsing as isLargeFile")
    func largeFileDownloadHandshake() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.largeFile.download")
        let clientConnection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        try await clientConnection.startAndWaitForReady(on: clientQueue)
        let serverConn = try await acceptedConnection

        let bigSize: UInt64 = 0x1_2345_6789 // ~4.9 GiB
        let actor = FileTransferActor(
            connection: clientConnection,
            queue: clientQueue,
            transferID: 0x0A0B0C0D,
            totalSize: bigSize,
            isLargeFile: true
        )

        async let preamble: Data = serverConn.receiveExactly(TransferHandshake.largeFileByteCount)
        try await actor.sendHandshake()

        let bytes = try await preamble
        #expect(bytes.count == TransferHandshake.largeFileByteCount)
        let parsed = TransferHandshake.parse(bytes)
        #expect(parsed?.isLargeFile == true)
        #expect(parsed?.transferID == 0x0A0B0C0D)
        #expect(parsed?.size == bigSize)

        serverConn.cancel()
    }

    @Test("normal download still sends a 16-byte handshake")
    func normalDownloadHandshake() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.normal.download")
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
            transferID: 42,
            totalSize: 1000
        )

        async let preamble: Data = serverConn.receiveExactly(TransferHandshake.byteCount)
        try await actor.sendHandshake()

        let bytes = try await preamble
        #expect(bytes.count == TransferHandshake.byteCount)
        let parsed = TransferHandshake.parse(bytes)
        #expect(parsed?.isLargeFile == false)
        #expect(parsed?.transferID == 42)

        serverConn.cancel()
    }

    @Test("finishUpload with empty trailer completes without throwing")
    func finishUploadEmptyTrailerCompletes() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()

        let clientQueue = DispatchQueue(label: "test.upload.empty.client")
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

        // Folder-upload-finalize shape: every byte has already gone
        // through `sendBytes`, then we close with no trailing data.
        var payloadBytes = [UInt8]()
        payloadBytes.reserveCapacity(4096)
        for i in 0..<4096 {
            payloadBytes.append(UInt8(i & 0xFF))
        }
        let payload = Data(payloadBytes)

        async let received: Data = serverConn.receiveExactly(16 + payload.count)

        try await actor.sendHandshake(transferSize: UInt32(payload.count))
        try await actor.sendBytes(payload)
        try await actor.finishUpload()

        let bytes = try await received
        #expect(bytes.count == 16 + payload.count)

        serverConn.cancel()
    }
}
#endif
