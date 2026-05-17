import Foundation
import Network

// Hotline file transfers happen on a separate TCP stream the server opens
// on demand; the reply to startDownload/startUpload contains a transferID
// and total size, and the client then dials the server again on the
// transfer port to read/write the actual bytes. The side-channel actor
// (FileTransferActor) plus the framing codecs in this package handle
// that stream end-to-end. The control-channel request/reply pairs below
// produce the TransferHandle that callers hand off to the side-channel.

extension HotlineNetworkClient {

    // MARK: - Transfers

    public func startDownload(
        at path: RemotePath,
        name: String,
        dataForkOffset: UInt32,
        resourceForkOffset: UInt32
    ) async throws -> TransferHandle {
        // Control channel: transID 202 — downloadFile.
        // Attach the 74-byte resume blob (objID 203) only when at least
        // one fork has an offset > 0 — bare downloads omit the field
        // entirely, matching HEClient.m line 1597.
        var fields: [PacketField] = [
            .string(.fileName, name, encoding: stringEncoding),
            .path(.filePath, path, encoding: stringEncoding)
        ]
        let resume = ResumeInfo(
            dataForkOffset: dataForkOffset,
            resourceForkOffset: resourceForkOffset
        )
        if !resume.isFresh {
            fields.append(PacketField(
                key: .fileResumeInfo,
                data: ResumeInfoCodec.encode(resume)
            ))
        }
        let reply = try await sendExpectingReply(
            transactionID: 202,
            fields: fields
        )
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }
        let totalSize = reply.uint32(.transferSize) ?? 0

        let actor = try await openSideChannel(transferID: transferID, totalSize: UInt64(totalSize))
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(totalSize))
    }

    public func startFolderDownload(at path: RemotePath, name: String) async throws -> TransferHandle {
        // Control channel: transID 210 — downloadFolder.
        // Fields per HEClient.m line 1700+: fileName(201), filePath(202).
        let reply = try await sendExpectingReply(
            transactionID: 210,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ]
        )
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }
        let totalSize = reply.uint32(.transferSize) ?? 0

        // Open the side channel with the 18-byte folder-download
        // handshake. Streaming the per-item file payloads is not yet
        // implemented — the bytes are arriving on the connection but
        // we don't have a parser for the interleaved item-header /
        // FILP / INFO / DATA stream yet (HETransferThread.m line 245+).
        // The caller can already iterate `downloadStream(for:)` to see
        // the raw bytes if they want to roll their own parser.
        let actor = try await openFolderSideChannel(
            transferID: transferID,
            totalSize: UInt64(totalSize),
            isDownload: true
        )
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(totalSize))
    }

    public func startUpload(at path: RemotePath, name: String, size: UInt32, resume: Bool) async throws -> TransferHandle {
        // Control channel: transID 203 — uploadFile.
        // Fields per HEClient.m line 1771+:
        //   filePath(202), transferSize(108)=size, fileName(201), [optional resume flag]
        var fields: [PacketField] = [
            .path(.filePath, path, encoding: stringEncoding),
            .uint32(.transferSize, size),
            .string(.fileName, name, encoding: stringEncoding)
        ]
        if resume {
            fields.append(.uint16(.parameter, 1))
        }
        let reply = try await sendExpectingReply(transactionID: 203, fields: fields)
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }

        let actor = try await openSideChannel(transferID: transferID, totalSize: UInt64(size))
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(size))
    }

    public func sendUpload(
        _ content: Data,
        for handle: TransferHandle,
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        progress: (@Sendable (UInt64) async -> Void)?
    ) async throws {
        guard let actor = activeTransfers[handle.transferID] else {
            throw HotlineError.notConnected
        }

        let nameBytes = fileName.data(using: stringEncoding, allowLossyConversion: true) ?? Data()
        let total = UploadFraming.totalSize(
            nameLength: nameBytes.count,
            dataLength: UInt32(content.count)
        )

        // Re-send the HTXF handshake with the now-known total size. The
        // server already saw the zero-size handshake from openSideChannel;
        // the original Heidrun also opens with `xFerSize=0` and the
        // server tolerates either flow. Be explicit anyway.
        try await actor.sendBytes(
            TransferHandshake.encode(transferID: handle.transferID, transferSize: total)
        )

        // FILP + INFO + DATA hdr, then data-fork bytes in chunks (so
        // progress fires mid-transfer), then MACR trailer.
        let prefix = UploadFraming.encodePrefix(
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            dataLength: UInt32(content.count),
            encoding: stringEncoding
        )
        try await actor.sendBytes(prefix)

        let chunkSize = 64 * 1024
        var offset = 0
        var sent: UInt64 = 0
        while offset < content.count {
            let end = min(offset + chunkSize, content.count)
            try await actor.sendBytes(content.subdata(in: offset..<end))
            sent &+= UInt64(end - offset)
            offset = end
            if let progress { await progress(sent) }
        }

        try await actor.sendBytes(UploadFraming.encodeSuffix())
        await actor.finishUpload()
        activeTransfers.removeValue(forKey: handle.transferID)
    }

    public func startFolderUpload(
        at path: RemotePath,
        name: String,
        size: UInt32,
        itemCount: UInt16,
        resume: Bool
    ) async throws -> TransferHandle {
        // Control channel: transID 213 — uploadFolder.
        // Fields per HEClient.m line 1860+:
        //   filePath(202), folderName(201), folderSize(108)=size,
        //   itemCount(220)=itemCount, optional folderResumeFlag(204)=1.
        var fields: [PacketField] = [
            .path(.filePath, path, encoding: stringEncoding),
            .string(.fileName, name, encoding: stringEncoding),
            .uint32(.transferSize, size),
            .uint16(.folderItemCount, itemCount)
        ]
        if resume {
            fields.append(.uint16(.folderResumeFlag, 1))
        }
        let reply = try await sendExpectingReply(transactionID: 213, fields: fields)
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }

        let actor = try await openFolderSideChannel(
            transferID: transferID,
            totalSize: UInt64(size),
            isDownload: false
        )
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(size))
    }

    /// Drive the per-item handshake for a folder upload started with
    /// `startFolderUpload(...)`. Sub-directories appear as items with
    /// `isDirectory == true` and empty `data`; files carry the data
    /// fork (resource fork is sent empty).
    public func sendFolderUpload(
        _ items: [FolderUploadItem],
        for handle: TransferHandle,
        type: FourCharCode = .file,
        creator: FourCharCode = .unknown,
        creationDate: Date = Date(),
        modificationDate: Date = Date()
    ) async throws {
        guard let actor = activeTransfers[handle.transferID] else {
            throw HotlineError.notConnected
        }

        var first = true
        for item in items {
            if !first {
                // Server sends `3` between items meaning "ready for the
                // next one". Anything else means it has decided to stop
                // and we should bail out.
                let next = try await actor.receiveUInt16()
                guard next == FolderUploadFraming.readyForNextItem else {
                    throw HotlineError.malformedReply(reason: "unexpected folder sync \(next)")
                }
            }
            first = false

            // 1) Send the per-item header (path components + isDir flag).
            let header = FolderUploadFraming.encodeItemHeader(
                relativePath: item.relativePath,
                isDirectory: item.isDirectory,
                encoding: stringEncoding
            )
            try await actor.sendBytes(header)

            // 2) Server replies with what to do for this entry: 1 upload,
            //    2 resume, 3 skip.
            guard let action = FolderUploadFraming.ItemAction(rawValue: try await actor.receiveUInt16()) else {
                throw HotlineError.malformedReply(reason: "unknown folder item action")
            }

            switch action {
            case .skip:
                continue
            case .resume:
                // Server sends UInt16 length + N bytes of resume info.
                // We parse the data-fork offset and skip that many bytes
                // off the front of our payload (resource fork is always
                // empty in this implementation).
                let blobSize = try await actor.receiveUInt16()
                let blob = try await actor.receiveExactly(Int(blobSize))
                let info = ResumeInfoCodec.decode(blob) ?? ResumeInfo()
                try await sendItemPayload(
                    item: item,
                    on: actor,
                    type: type,
                    creator: creator,
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    dataForkOffset: info.dataForkOffset
                )
            case .upload:
                try await sendItemPayload(
                    item: item,
                    on: actor,
                    type: type,
                    creator: creator,
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    dataForkOffset: 0
                )
            }
        }

        await actor.finishUpload()
        activeTransfers.removeValue(forKey: handle.transferID)
    }

    private func sendItemPayload(
        item: FolderUploadItem,
        on actor: FileTransferActor,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        dataForkOffset: UInt32 = 0
    ) async throws {
        guard !item.isDirectory else { return }
        let fileName = item.relativePath.last ?? ""
        let nameBytes = fileName.data(using: stringEncoding, allowLossyConversion: true) ?? Data()

        // Skip the prefix the server already has on disk for resumes.
        let dataPayload: Data
        let offset = Int(dataForkOffset)
        if offset >= item.data.count {
            dataPayload = Data()
        } else if offset > 0 {
            dataPayload = item.data.suffix(from: item.data.startIndex + offset)
        } else {
            dataPayload = item.data
        }

        let total = UploadFraming.totalSize(
            nameLength: nameBytes.count,
            dataLength: UInt32(dataPayload.count)
        )

        // The server expects the per-item total size as a UInt32 before
        // the FILP block (HETransferThread.m line 904).
        var sizeBytes = Data()
        sizeBytes.appendBigEndian(total)
        try await actor.sendBytes(sizeBytes)

        let framed = UploadFraming.encode(
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            data: dataPayload,
            encoding: stringEncoding
        )
        try await actor.sendBytes(framed)
    }

    public func cancelTransfer(_ handle: TransferHandle) async throws {
        // Tell the server to abort: trans=214, transferID(107) field.
        // Without this the server keeps streaming bytes until our side-
        // channel TCP drops, holding its transfer-queue slot open the
        // whole time. Sent before the local actor tear-down so the wire
        // notification is on its way before we stop draining the socket.
        // `try?` because the user-visible cancel must not fail if the
        // main connection is itself wobbling — local cleanup still runs.
        var transferIDBytes = Data()
        transferIDBytes.appendBigEndian(handle.transferID)
        _ = try? await sendNoReply(
            transactionID: 214,
            fields: [PacketField(key: .transferID, data: transferIDBytes)]
        )
        if let actor = activeTransfers.removeValue(forKey: handle.transferID) {
            await actor.cancel()
        }
    }

    nonisolated public func downloadStream(for handle: TransferHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                guard let actor = await self.transferActor(for: handle.transferID) else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                for try await chunk in actor.bytes() {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    /// Stream the contents of a folder download started with
    /// `startFolderDownload(...)`. Each element is one file or directory
    /// the server is sending; the data fork lives in `data`, while
    /// sub-directories arrive with `isDirectory == true` and empty data.
    ///
    /// Directories are ACK'd with action=3 (skip) and acted on locally;
    /// files are ACK'd with action=1 (download), or action=2 + an RFLT
    /// blob when `resumeProvider` says we already have a partial copy.
    /// In the resume case each item's `dataForkOffset` tells the caller
    /// where to write the incoming bytes.
    nonisolated public func folderDownloadStream(
        for handle: TransferHandle,
        resumeProvider: FolderDownloadResumeProvider? = nil
    ) -> AsyncThrowingStream<FolderDownloadItem, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                guard let actor = await self.transferActor(for: handle.transferID) else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                let encoding = self.stringEncoding
                await FolderDownloadDecoder.drive(
                    actor: actor,
                    encoding: encoding,
                    resumeProvider: resumeProvider,
                    continuation: continuation
                )
                continuation.finish()
                await self.discardTransfer(transferID: handle.transferID)
            }
        }
    }

    private func discardTransfer(transferID: UInt32) {
        if let actor = activeTransfers.removeValue(forKey: transferID) {
            Task { await actor.cancel() }
        }
    }

    // MARK: - Side-channel helpers

    private func transferActor(for transferID: UInt32) -> FileTransferActor? {
        activeTransfers[transferID]
    }

    /// Open a fresh TCP connection to the server's transfer port (control
    /// port + 1), perform the HTXF handshake, and hand back the actor
    /// that wraps the connection.
    private func openSideChannel(transferID: UInt32, totalSize: UInt64) async throws -> FileTransferActor {
        let host = NWEndpoint.Host(connectionSettings.address)
        guard let port = NWEndpoint.Port(rawValue: connectionSettings.port &+ 1) else {
            throw HotlineError.notConnected
        }
        let sideQueue = DispatchQueue(label: "Heidrun.transfer.\(transferID)")
        let sideConnection = NWConnection(host: host, port: port, using: .tcp)
        try await sideConnection.startAndWaitForReady(on: sideQueue)

        let actor = FileTransferActor(
            connection: sideConnection,
            queue: sideQueue,
            transferID: transferID,
            totalSize: totalSize
        )
        try await actor.sendHandshake(transferSize: 0)
        return actor
    }

    /// Same as `openSideChannel(...)` but sends one of the folder-flavour
    /// HTXF preambles instead of the regular 16-byte handshake.
    private func openFolderSideChannel(
        transferID: UInt32,
        totalSize: UInt64,
        isDownload: Bool
    ) async throws -> FileTransferActor {
        let host = NWEndpoint.Host(connectionSettings.address)
        guard let port = NWEndpoint.Port(rawValue: connectionSettings.port &+ 1) else {
            throw HotlineError.notConnected
        }
        let sideQueue = DispatchQueue(label: "Heidrun.transfer.\(transferID)")
        let sideConnection = NWConnection(host: host, port: port, using: .tcp)
        try await sideConnection.startAndWaitForReady(on: sideQueue)

        let actor = FileTransferActor(
            connection: sideConnection,
            queue: sideQueue,
            transferID: transferID,
            totalSize: totalSize
        )
        let handshake = isDownload
            ? TransferHandshake.encodeFolderDownload(transferID: transferID)
            : TransferHandshake.encodeFolderUpload(transferID: transferID)
        try await actor.sendBytes(handshake)
        return actor
    }
}
