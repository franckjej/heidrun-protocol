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
/// 40-byte FILP header (last 4 bytes = UInt32 infoBlockLength)
/// infoBlockLength bytes:
///   "AMAC" + UInt32 type + UInt32 creator + 40 reserved
///   + UInt16 baseYear + 2 reserved + UInt32 creationDateSecs
///   + UInt16 baseYear + 2 reserved + UInt32 modificationDateSecs
///   + 2 reserved + UInt16 nameLen + name + UInt16 commentLen + comment
/// 16-byte DATA fork header (last 4 bytes = UInt32 dataLength)
/// dataLength bytes of data fork
/// 16-byte MACR fork header (last 4 bytes = UInt32 resourceLength)
/// resourceLength bytes of resource fork  (discarded — modern macOS
///                                          doesn't use them)
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
        resumeProvider: FolderDownloadResumeProvider? = nil,
        continuation: AsyncThrowingStream<FolderDownloadItem, Error>.Continuation
    ) async {
        do {
            while true {
                guard let item = try await readItem(
                    actor: actor,
                    encoding: encoding,
                    resumeProvider: resumeProvider
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
        resumeProvider: FolderDownloadResumeProvider?
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

        // File path: itemFileSize, then FILP + INFO + DATA + MACR.
        let itemFileSizeBytes = try await actor.receiveExactly(4)
        _ = itemFileSizeBytes  // size lives inside the FILP block; this is informational.

        let filp = try await actor.receiveExactly(40)
        var filpCursor = ByteCursor(data: filp, offset: 36)
        let infoLength: UInt32 = filpCursor.readBigEndian()

        let infoBytes = try await actor.receiveExactly(Int(infoLength))
        let meta = parseInfoBlock(infoBytes, encoding: encoding)

        let dataHeader = try await actor.receiveExactly(16)
        var dataCursor = ByteCursor(data: dataHeader, offset: 12)
        let dataLength: UInt32 = dataCursor.readBigEndian()
        let dataFork = try await actor.receiveExactly(Int(dataLength))

        let macrHeader = try await actor.receiveExactly(16)
        var macrCursor = ByteCursor(data: macrHeader, offset: 12)
        let resLength: UInt32 = macrCursor.readBigEndian()
        if resLength > 0 {
            _ = try await actor.receiveExactly(Int(resLength))
        }

        return FolderDownloadItem(
            relativePath: parsed.components,
            isDirectory: false,
            data: dataFork,
            dataForkOffset: dataForkOffset,
            type: FourCharCode(rawValue: meta.type),
            creator: FourCharCode(rawValue: meta.creator),
            creationDate: HotlineDate.decode(baseYear: meta.creBaseYear, seconds: meta.creSeconds),
            modificationDate: HotlineDate.decode(baseYear: meta.modBaseYear, seconds: meta.modSeconds),
            comment: meta.comment
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

    struct InfoBlockMetadata {
        let type: UInt32
        let creator: UInt32
        let creBaseYear: UInt16
        let creSeconds: UInt32
        let modBaseYear: UInt16
        let modSeconds: UInt32
        let name: String
        let comment: String
    }

    /// Parse the INFO block that follows the 40-byte FILP header.
    /// Layout transcribed from HETransferThread.m line 365+.
    static func parseInfoBlock(_ data: Data, encoding: String.Encoding) -> InfoBlockMetadata {
        var cursor = ByteCursor(data: data)
        _ = cursor.readData(count: 4)                  // "AMAC"
        let type: UInt32 = cursor.readBigEndian()
        let creator: UInt32 = cursor.readBigEndian()
        _ = cursor.readData(count: 40)                 // 4 reserved + UInt32 256 + 32 reserved

        let creBaseYear: UInt16 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)                  // reserved
        let creSeconds: UInt32 = cursor.readBigEndian()

        let modBaseYear: UInt16 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)                  // reserved
        let modSeconds: UInt32 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)                  // reserved

        let nameLen: UInt16 = cursor.readBigEndian()
        let nameBytes = cursor.readData(count: Int(nameLen))
        let name = String(data: nameBytes, encoding: encoding) ?? ""

        let commentLen: UInt16 = cursor.remaining >= 2 ? cursor.readBigEndian() : 0
        let commentBytes = cursor.readData(count: Int(commentLen))
        let comment = String(data: commentBytes, encoding: encoding) ?? ""

        return InfoBlockMetadata(
            type: type,
            creator: creator,
            creBaseYear: creBaseYear,
            creSeconds: creSeconds,
            modBaseYear: modBaseYear,
            modSeconds: modSeconds,
            name: name,
            comment: comment
        )
    }
}
#endif
