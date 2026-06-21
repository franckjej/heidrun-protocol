import Foundation
import NIOCore
import NIOPosix
import HeidrunCore

/// One-shot side-channel TCP connection for a Hotline file transfer.
///
/// Hotline file transfers don't ride the control connection — instead
/// the server's reply to a download/upload request hands back a
/// `transferID`, and the client dials the server again on
/// `controlPort + 1`. The first 16 bytes over that side channel are
/// the HTXF handshake (magic + id + size + reserved), after which
/// the bytes flow in one direction (server → client for download,
/// client → server for upload).
///
/// This namespace stays at file scope (not on `NIOHotlineClient`) so
/// the actor isolation doesn't get in the way of streaming reads or
/// writes — every call opens its own channel and closes it at the
/// end. The Darwin client does the equivalent via `FileTransferActor`.
enum NIOTransferConnection {

    /// 64 KiB read/write chunks. Big enough that the TCP window stays
    /// filled; small enough that the progress callback fires at a
    /// usable resolution (≈ 16× per MB).
    private static let chunkSize = 64 * 1024

    // MARK: - Download

    /// Stream a transfer's data-fork bytes from `host:transferPort` to
    /// `destination`. `transferID` + `totalSize` come from the control
    /// channel's TX 202 reply. Overwrites any existing file at the
    /// destination path. Streams via `FileHandle` so a multi-GB
    /// transfer doesn't hold the file in memory.
    static func download(
        host: String,
        transferPort: UInt16,
        transferID: UInt32,
        totalSize: UInt32,
        to destination: URL,
        progress: (@Sendable (UInt64, UInt64) async -> Void)?
    ) async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(InboundByteBridge(continuation: continuation))
            }
        let channel = try await bootstrap.connect(
            host: host, port: Int(transferPort)
        ).get()
        defer { _ = channel.close() }

        try await writeData(
            TransferHandshake.encode(transferID: transferID, transferSize: totalSize),
            on: channel
        )

        // Prepare destination — overwrite any prior partial download
        // at this path.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // Discard the Bool: a failure here surfaces as a descriptive error
        // from the FileHandle open on the next line.
        _ = fileManager.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let reader = ByteAccumulator(stream: stream)
        var received: UInt64 = 0
        let total = UInt64(totalSize)
        while received < total {
            let remaining = total - received
            let want = Int(min(remaining, UInt64(chunkSize)))
            let chunk = try await reader.receiveExactly(want)
            try handle.write(contentsOf: chunk)
            received += UInt64(chunk.count)
            if let progress {
                await progress(received, total)
            }
        }
    }

    // MARK: - Upload

    /// Stream a local file at `source` to `host:transferPort` as a
    /// Hotline upload. Builds the FILP / INFO / DATA-hdr prefix from
    /// the supplied metadata, streams the data fork in chunks from
    /// disk, then sends the MACR trailer plus any resource-fork bytes.
    /// `totalBytes` is computed via `UploadFraming.totalSize` and
    /// passed in the HTXF preamble so the server knows when to stop
    /// reading.
    ///
    /// `resourceFork` is passed by value rather than read from disk —
    /// resource forks are typically small (<<1 MB) so loading them up
    /// front avoids a second `FileHandle` and keeps the streaming path
    /// honest about how many bytes it owes the server.
    ///
    /// `creationDate` / `modificationDate` are sourced from the file's
    /// own attributes by the caller — passing them in (rather than
    /// reading attributes here) keeps this function pure I/O so a
    /// future test fake can swap in deterministic dates.
    static func upload(
        host: String,
        transferPort: UInt16,
        transferID: UInt32,
        source: URL,
        fileSize: UInt32,
        fileName: String,
        type: HeidrunCore.FourCharCode,
        creator: HeidrunCore.FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        resourceFork: Data = Data(),
        encoding: String.Encoding = .macOSRoman,
        progress: (@Sendable (UInt64, UInt64) async -> Void)?
    ) async throws {
        let nameBytes = fileName.data(using: encoding, allowLossyConversion: true) ?? Data()
        let totalSize = UploadFraming.totalSize(
            nameLength: nameBytes.count,
            dataLength: fileSize,
            resourceLength: UInt32(resourceFork.count)
        )
        let prefix = UploadFraming.encodePrefix(
            fileName: fileName,
            type: type, creator: creator,
            creationDate: creationDate, modificationDate: modificationDate,
            dataLength: UInt64(fileSize),
            encoding: encoding
        )
        let suffix = UploadFraming.encodeSuffix(resourceFork: resourceFork)

        // Inbound bytes on an upload aren't read by us — the server
        // never replies on this side channel; the control channel
        // emits the "transfer complete" notice. We still install the
        // InboundByteBridge so NIO's pipeline is complete; `stream` is
        // intentionally unused.
        let (_, continuation) = AsyncStream<Data>.makeStream()
        defer { continuation.finish() }
        let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(InboundByteBridge(continuation: continuation))
            }
        let channel = try await bootstrap.connect(
            host: host, port: Int(transferPort)
        ).get()
        defer { _ = channel.close() }

        try await writeData(
            TransferHandshake.encode(transferID: transferID, transferSize: totalSize),
            on: channel
        )
        try await writeData(prefix, on: channel)

        // Data fork — stream from disk so a multi-GB upload doesn't
        // sit in memory. `FileHandle.readData(ofLength:)` returns an
        // empty Data at EOF, which is the natural loop termination.
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var sent: UInt64 = 0
        let total = UInt64(fileSize)
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            try await writeData(chunk, on: channel)
            sent += UInt64(chunk.count)
            if let progress {
                await progress(sent, total)
            }
        }

        try await writeData(suffix, on: channel)
    }

    // MARK: - Helpers

    private static func writeData(_ data: Data, on channel: Channel) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }
}
