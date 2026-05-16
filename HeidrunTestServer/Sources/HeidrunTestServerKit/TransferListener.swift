import Foundation
import Network
import HeidrunCore

/// Side-channel transfer dispatcher.
///
/// Each inbound HTXF connection sends a 16-byte handshake; the static
/// `handle` reads the `transferID` out of it, looks it up in
/// `ServerState.takeTransfer(id:)` and then either streams file bytes
/// out (download) or drains the framed FILP/INFO/DATA/MACR envelope and
/// commits the data fork to the VFS (upload). `TestServerInstance`
/// installs this as the transfer listener's connection handler.
enum TransferListener {

    static func handle(
        connection: NWConnection,
        state: ServerState,
        queue: DispatchQueue
    ) async {
        do {
            try await connection.startAndWaitForReady(on: queue)

            // The client always sends the 16-byte HTXF preamble first.
            // Folder-flavour transfers send 16 (upload) or 18 (download)
            // bytes; for single-file transfers (the only ones the test
            // server models) 16 is enough.
            let preamble = try await connection.receiveExactly(TransferHandshake.byteCount)
            guard preamble.prefix(4) == Data(TransferHandshake.magic) else {
                connection.cancel()
                return
            }
            let transferID = readBEUInt32(preamble, at: 4)
            let transferSize = readBEUInt32(preamble, at: 8)

            guard let pending = await state.takeTransfer(id: transferID) else {
                connection.cancel()
                return
            }

            switch pending {
            case .download(let path, let name, let offset):
                try await streamDownload(
                    connection: connection,
                    path: path,
                    name: name,
                    offset: offset,
                    state: state
                )
            case .upload(let path, let name, let size, let resume):
                try await drainUpload(
                    connection: connection,
                    path: path,
                    name: name,
                    declaredSize: size,
                    transferSize: transferSize,
                    resume: resume,
                    state: state
                )
            }
        } catch {
            // Connection closed mid-transfer; cancel and move on. The
            // production client surfaces this as a failed transfer state.
        }
        connection.cancel()
    }

    // MARK: - Download side

    /// Bare-bones single-file download: write `data[offset..<end]` to the
    /// side channel and close. The production client iterates these
    /// bytes raw into the destination file (no FILP envelope).
    private static func streamDownload(
        connection: NWConnection,
        path: [String],
        name: String,
        offset: UInt32,
        state: ServerState
    ) async throws {
        guard let bytes = state.vfs.bytes(at: path, name: name) else {
            return
        }
        let start = min(Int(offset), bytes.count)
        let tail = bytes.suffix(from: bytes.startIndex.advanced(by: start))
        let chunkSize = 16 * 1024
        // Per-chunk sleep when the CLI asked for a throttle. Floored at
        // 1ms so the runtime can actually honour the request — sub-ms
        // sleeps round down to zero and are indistinguishable from
        // unthrottled on the wire.
        let throttleKBps = state.downloadThrottleKBps
        let perChunkSleep: Duration? = throttleKBps > 0
            ? .milliseconds(max(1, Int((Double(chunkSize) / Double(UInt32(1024) &* throttleKBps)) * 1000)))
            : nil
        var current = tail.startIndex
        while current < tail.endIndex {
            let end = tail.index(current, offsetBy: chunkSize, limitedBy: tail.endIndex) ?? tail.endIndex
            try await connection.sendAsync(Data(tail[current..<end]))
            if let perChunkSleep {
                try await Task.sleep(for: perChunkSleep)
            }
            current = end
        }
    }

    // MARK: - Upload side

    private static func drainUpload(
        connection: NWConnection,
        path: [String],
        name: String,
        declaredSize: UInt32,
        transferSize: UInt32,
        resume: Bool,
        state: ServerState
    ) async throws {
        // The total bytes that will arrive after the preamble. The
        // client re-sends the HTXF handshake with the real transferSize
        // once it knows the framing total (see `sendUpload` in
        // HotlineNetworkClient+Transfers.swift), so we honour either the
        // declared size or the second handshake — whichever is non-zero.
        var payload = Data()

        // If the client re-sent the handshake (with non-zero size), the
        // first 16 bytes on the wire after our initial drain will be a
        // second HTXF preamble. Peek for it.
        let firstChunk = try await connection.receiveExactly(16)
        let total: UInt32
        if firstChunk.prefix(4) == Data(TransferHandshake.magic) {
            // Second handshake; use its transferSize field.
            total = readBEUInt32(firstChunk, at: 8)
        } else {
            // No second handshake; firstChunk is the start of the FILP
            // envelope. Use the first preamble's size field, or the
            // declared size.
            payload.append(firstChunk)
            total = transferSize == 0 ? declaredSize : transferSize
        }

        let remaining = Int(total) - payload.count
        if remaining > 0 {
            let rest = try await connection.receiveExactly(remaining)
            payload.append(rest)
        }

        // Parse the FILP/INFO/DATA/MACR envelope and commit to the VFS.
        let parsed = try UploadFramingParser.parse(payload)
        let storedName = parsed.fileName.isEmpty ? name : parsed.fileName
        if resume,
           let existing = state.vfs.bytes(at: path, name: storedName),
           !existing.isEmpty {
            state.vfs.appendBytes(at: path, name: storedName, data: parsed.data)
        } else {
            state.vfs.putFile(
                at: path,
                name: storedName,
                data: parsed.data,
                type: parsed.type,
                creator: parsed.creator
            )
        }
    }

    private static func readBEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex.advanced(by: offset)
        return UInt32(data[base]) << 24
             | UInt32(data[base + 1]) << 16
             | UInt32(data[base + 2]) << 8
             | UInt32(data[base + 3])
    }
}
