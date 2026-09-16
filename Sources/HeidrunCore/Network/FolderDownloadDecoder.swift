#if canImport(Network)
import Foundation

/// One entry yielded while a folder download streams.
public struct FolderDownloadItem: Sendable {
    public let relativePath: [String]
    public let isDirectory: Bool
    /// Data fork bytes. Empty for directories. When `dataForkOffset > 0`
    /// these are the bytes the caller should *append* to the existing
    /// partial file at that offset.
    public let data: Data
    /// Resource fork bytes. Empty for directories and data-fork-only
    /// files. Carries whatever the server wrote into the per-item MACR
    /// block.
    public let resourceFork: Data
    /// Where the `data` bytes belong in the destination file. `0` for a
    /// fresh download; the value the caller's resume provider returned
    /// when resuming.
    public let dataForkOffset: UInt32
    public let type: FourCharCode
    public let creator: FourCharCode
    public let creationDate: Date
    public let modificationDate: Date
    public let comment: String

    public init(
        relativePath: [String],
        isDirectory: Bool,
        data: Data = Data(),
        resourceFork: Data = Data(),
        dataForkOffset: UInt32 = 0,
        type: FourCharCode = .file,
        creator: FourCharCode = .unknown,
        creationDate: Date = Date.distantPast,
        modificationDate: Date = Date.distantPast,
        comment: String = ""
    ) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.data = data
        self.resourceFork = resourceFork
        self.dataForkOffset = dataForkOffset
        self.type = type
        self.creator = creator
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.comment = comment
    }
}

/// Caller-supplied lookup for "do I already have a partial copy of this
/// file?" Folder downloads call this for every file item; returning a
/// non-fresh `ResumeInfo` makes the decoder ask the server to resume
/// from that offset instead of starting over.
public typealias FolderDownloadResumeProvider = @Sendable ([String]) -> ResumeInfo?

/// Streaming decoder for the server's side of a folder download.
///
/// Wire layout per item (HETransferThread.m line 245+):
///
/// ```text
/// UInt16 folderHeaderSize
/// folderHeaderSize bytes:
///   UInt16 folderType        // even = file, odd = sub-directory
///   UInt16 componentCount
///   per component: UInt16 0 + UInt8 length + name bytes
/// ```
///
/// Client replies with `UInt16 action`:
///   1 = download this file
///   2 = resume — followed by 74 bytes of resume info
///   3 = skip (used for directories: we just create them locally)
///
/// For action 1 or 2 the server then sends:
///
/// ```text
/// UInt32 itemFileSize        // total remaining bytes for this item
/// FILP envelope (see `FlattenedFileStream`): INFO + DATA forks, plus
/// MACR when the file has a resource fork (surfaced on the yielded
/// item as `resourceFork`)
/// ```
public enum FolderDownloadDecoder {

    /// Action bytes the client replies with after each item header.
    enum Action: UInt16 {
        case download = 1
        case resume   = 2
        case skip     = 3
    }

    /// Drive one folder-download conversation against `actor`, yielding
    /// each item to `continuation`. Stops cleanly when the server closes
    /// the connection between items.
    ///
    /// When `resumeProvider` is non-nil, each *file* item the server
    /// announces is looked up by relative path. If the provider returns
    /// a non-fresh `ResumeInfo`, the decoder ACKs with action=2 plus the
    /// 74-byte RFLT blob and the server resumes from that offset.
    public static func drive(
        actor: FileTransferActor,
        encoding: String.Encoding,
        largeFile: Bool = false,
        resumeProvider: FolderDownloadResumeProvider? = nil,
        progress: (@Sendable (Int) async -> Void)? = nil,
        continuation: AsyncThrowingStream<FolderDownloadItem, Error>.Continuation
    ) async {
        do {
            while true {
                guard let item = try await readItem(
                    actor: actor,
                    encoding: encoding,
                    largeFile: largeFile,
                    resumeProvider: resumeProvider,
                    progress: progress
                ) else {
                    return
                }
                continuation.yield(item)
            }
        } catch HotlineError.notConnected {
            // Clean EOF between items — server done.
            return
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Build the bytes the client sends back after a file item header.
    /// `nil`/fresh resume → action=1 (download); otherwise action=2 plus
    /// the 74-byte RFLT blob.
    static func encodeFileAck(resume: ResumeInfo?) -> Data {
        var bytes = Data()
        if let resume, !resume.isFresh {
            bytes.appendBigEndian(Action.resume.rawValue)
            bytes.append(ResumeInfoCodec.encode(resume))
        } else {
            bytes.appendBigEndian(Action.download.rawValue)
        }
        return bytes
    }

    /// Read a single item from the side channel, sending the action ACK
    /// at the right moment. Returns `nil` when the server signals end of
    /// stream by sending a zero-length item header.
    private static func readItem(
        actor: FileTransferActor,
        encoding: String.Encoding,
        largeFile: Bool = false,
        resumeProvider: FolderDownloadResumeProvider?,
        progress: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> FolderDownloadItem? {
        let headerSize = try await actor.receiveUInt16()
        guard headerSize > 0 else { return nil }

        let headerBytes = try await actor.receiveExactly(Int(headerSize))
        let parsed = parseItemHeader(headerBytes, encoding: encoding)

        if parsed.isDirectory {
            var actionBytes = Data()
            actionBytes.appendBigEndian(Action.skip.rawValue)
            try await actor.sendBytes(actionBytes)
            return FolderDownloadItem(
                relativePath: parsed.components,
                isDirectory: true
            )
        }

        let resume = resumeProvider?(parsed.components)
        try await actor.sendBytes(encodeFileAck(resume: resume))
        let dataForkOffset = resume?.dataForkOffset ?? 0

        // File path: itemFileSize prefix, then the FILP envelope.
        // Legacy sessions announce the prefix as a UInt32; large-file
        // sessions widen it to a UInt64. The value is informational (the
        // authoritative fork lengths live in the fork headers), so we
        // read past it without using it beyond keeping the cursor aligned.
        _ = try await actor.receiveExactly(largeFile ? 8 : 4)

        // The envelope decoder sizes every read from the fork headers and
        // hands the data fork over in windows so callers can show live
        // progress instead of a single jump when the whole file lands.
        var dataFork = Data()
        let envelope = try await FlattenedFileStream.decode(
            readExactly: { try await actor.receiveExactly($0) },
            encoding: encoding,
            onData: { chunk in
                dataFork.append(chunk)
                await progress?(chunk.count)
            }
        )

        return FolderDownloadItem(
            relativePath: parsed.components,
            isDirectory: false,
            data: dataFork,
            resourceFork: envelope.resourceFork,
            dataForkOffset: dataForkOffset,
            type: envelope.metadata.type,
            creator: envelope.metadata.creator,
            creationDate: envelope.metadata.creationDate,
            modificationDate: envelope.metadata.modificationDate,
            comment: envelope.metadata.comment
        )
    }

    // MARK: - Header parsing

    struct ParsedItemHeader {
        let isDirectory: Bool
        let components: [String]
    }

    static func parseItemHeader(_ data: Data, encoding: String.Encoding) -> ParsedItemHeader {
        var cursor = ByteCursor(data: data)
        let folderType: UInt16 = cursor.readBigEndian()
        let count: UInt16 = cursor.readBigEndian()
        var components: [String] = []
        components.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard cursor.remaining >= 3 else { break }
            _ = cursor.readData(count: 2)               // pad
            let lenByte = cursor.readData(count: 1)
            let length = Int(lenByte.first ?? 0)
            guard cursor.remaining >= length else { break }
            let nameBytes = cursor.readData(count: length)
            components.append(String(data: nameBytes, encoding: encoding) ?? "")
        }
        return ParsedItemHeader(
            isDirectory: folderType.isMultiple(of: 2) == false,
            components: components
        )
    }
}
#endif
