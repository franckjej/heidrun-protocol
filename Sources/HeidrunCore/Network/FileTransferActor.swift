import Foundation
import Network

/// Owns one transfer-port `NWConnection` for the duration of a single
/// download or upload.
///
/// Hotline routes file bytes on a separate TCP connection from the
/// control channel: the server advertises a transfer port one above the
/// control port, and the client opens its own connection there for each
/// transfer it kicks off via the control channel. This actor models that
/// secondary connection.
///
/// Current scope: downloads only. The server hands us a stream of bytes
/// (no further framing on top of the 16-byte handshake we send first);
/// `bytes()` exposes them as an `AsyncThrowingStream<Data, Error>` so the
/// caller can write them straight to disk, or accumulate, or whatever.
/// Uploads and the folder-transfer side-protocol live behind separate
/// methods to be added later.
public actor FileTransferActor {
    public let transferID: UInt32
    public let totalSize: UInt64

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var bytesReceived: UInt64 = 0
    private var torn = false

    public init(
        connection: NWConnection,
        queue: DispatchQueue,
        transferID: UInt32,
        totalSize: UInt64
    ) {
        self.connection = connection
        self.queue = queue
        self.transferID = transferID
        self.totalSize = totalSize
    }

    /// Send the 16-byte HTXF handshake. Run once after the connection has
    /// reached `.ready` and before the caller iterates `bytes()`.
    public func sendHandshake(transferSize: UInt32 = 0) async throws {
        let bytes = TransferHandshake.encode(transferID: transferID, transferSize: transferSize)
        try await connection.sendAsync(bytes)
    }

    /// Stream raw bytes (already framed) to the side channel. Closes the
    /// connection on completion so the server sees EOF.
    public func sendBytes(_ data: Data) async throws {
        guard !torn else { throw HotlineError.cancelled }
        try await connection.sendAsync(data)
    }

    /// Mark the transfer as complete from the sender side and tear down
    /// the connection.
    public func finishUpload() {
        guard !torn else { return }
        torn = true
        connection.cancel()
    }

    /// Read exactly `count` bytes from the side channel. Used for the
    /// folder-upload protocol's per-item ACKs.
    public func receiveExactly(_ count: Int) async throws -> Data {
        guard !torn else { throw HotlineError.cancelled }
        return try await connection.receiveExactly(count)
    }

    /// Read a big-endian UInt16 from the side channel.
    public func receiveUInt16() async throws -> UInt16 {
        let bytes = try await receiveExactly(2)
        var cursor = ByteCursor(data: bytes)
        return cursor.readBigEndian()
    }

    /// Hand back an `AsyncThrowingStream` of byte chunks. Each call
    /// returns a fresh stream; only one consumer per transfer is
    /// expected — second calls return a stream that finishes immediately.
    nonisolated public func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.attach(continuation: continuation) }
        }
    }

    /// Cancel the underlying connection and fail the active stream.
    public func cancel() {
        guard !torn else { return }
        torn = true
        connection.cancel()
        continuation?.finish(throwing: HotlineError.cancelled)
        continuation = nil
        readerTask?.cancel()
        readerTask = nil
    }

    // MARK: - Private

    private func attach(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        guard !torn else {
            continuation.finish()
            return
        }
        guard self.continuation == nil else {
            continuation.finish()
            return
        }
        self.continuation = continuation
        continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            Task { await self.handleConsumerTermination(reason: reason) }
        }
        readerTask = Task { [weak self] in
            await self?.runReader()
        }
    }

    private func handleConsumerTermination(reason: AsyncThrowingStream<Data, Error>.Continuation.Termination) {
        // The consumer dropped its iterator. Tear down the connection
        // unless we already finished naturally.
        if !torn { cancel() }
    }

    private func runReader() async {
        let chunkSize = 16 * 1024
        while !torn && bytesReceived < totalSize {
            let remaining = totalSize - bytesReceived
            let want = Int(min(UInt64(chunkSize), remaining))
            do {
                let chunk = try await connection.receiveExactly(want)
                bytesReceived &+= UInt64(chunk.count)
                continuation?.yield(chunk)
            } catch {
                if !torn {
                    continuation?.finish(throwing: error)
                    continuation = nil
                    torn = true
                    connection.cancel()
                }
                return
            }
        }
        // Reached the end normally.
        if !torn {
            continuation?.finish()
            continuation = nil
            torn = true
            connection.cancel()
        }
    }
}
