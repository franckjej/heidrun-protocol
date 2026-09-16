import Foundation

/// Streaming decoder for the flattened file object (`FILP`) a Hotline
/// server ships on a single-file download.
///
/// Reads are sized from the fork headers, never from the outer transfer
/// size the control channel announced — some servers put the data-fork
/// size there, and a decoder that trusted it would stop short. The data
/// fork is handed to `onData` in windows so callers can stream it to
/// disk; the INFO metadata and the (usually small) MACR resource fork
/// come back in the result. Forks arrive in the order the server wrote
/// them; unknown fork types are skipped by length.
public enum FlattenedFileStream {

    public struct Metadata: Sendable, Hashable {
        public var fileName: String
        public var type: FourCharCode
        public var creator: FourCharCode
        public var creationDate: Date
        public var modificationDate: Date
        public var comment: String
    }

    public struct Result: Sendable {
        public var metadata: Metadata
        public var resourceFork: Data
    }

    /// Fixed-size FILP header: magic + version + 16 reserved + fork count.
    static let headerByteCount = 24
    static let forkHeaderByteCount = 16

    public static func decode(
        readExactly: (Int) async throws -> Data,
        encoding: String.Encoding = .macOSRoman,
        window: Int = 64 * 1024,
        onData: (Data) async throws -> Void
    ) async throws -> Result {
        let header = try await readExactly(headerByteCount)
        guard magic(of: header) == "FILP" else {
            throw UploadFraming.DecodeError.missingMagic("FILP")
        }
        var headerCursor = ByteCursor(data: header, offset: 22)
        let forkCount: UInt16 = headerCursor.readBigEndian()
        guard forkCount > 0 else { throw UploadFraming.DecodeError.truncated }

        var metadata: Metadata?
        var resourceFork = Data()
        for _ in 0..<forkCount {
            let forkHeader = try await readExactly(forkHeaderByteCount)
            let length = UploadFraming.forkLength(from: forkHeader)
            guard length <= UInt64(Int.max) else { throw UploadFraming.DecodeError.truncated }
            let byteCount = Int(length)
            switch magic(of: forkHeader) {
            case "INFO":
                metadata = parseInfoBlock(try await readExactly(byteCount), encoding: encoding)
            case "DATA":
                var remaining = byteCount
                while remaining > 0 {
                    let chunk = try await readExactly(min(window, remaining))
                    remaining -= chunk.count
                    try await onData(chunk)
                }
            case "MACR":
                resourceFork = byteCount > 0 ? try await readExactly(byteCount) : Data()
            default:
                var remaining = byteCount
                while remaining > 0 {
                    remaining -= try await readExactly(min(window, remaining)).count
                }
            }
        }
        guard let metadata else { throw UploadFraming.DecodeError.missingMagic("INFO") }
        return Result(metadata: metadata, resourceFork: resourceFork)
    }

    private static func magic(of data: Data) -> String {
        String(data: data.prefix(4), encoding: .ascii) ?? ""
    }

    /// Parse the INFO block that follows its fork header. Layout per
    /// HETransferThread.m line 365+.
    static func parseInfoBlock(_ data: Data, encoding: String.Encoding) -> Metadata {
        var cursor = ByteCursor(data: data)
        _ = cursor.readData(count: 4)                  // "AMAC"
        let type: UInt32 = cursor.readBigEndian()
        let creator: UInt32 = cursor.readBigEndian()
        _ = cursor.readData(count: 40)                 // 4 reserved + UInt32 256 + 32 reserved
        let creationBaseYear: UInt16 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)
        let creationSeconds: UInt32 = cursor.readBigEndian()
        let modificationBaseYear: UInt16 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)
        let modificationSeconds: UInt32 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)
        let nameLength: UInt16 = cursor.readBigEndian()
        let name = String(data: cursor.readData(count: Int(nameLength)), encoding: encoding) ?? ""
        let commentLength: UInt16 = cursor.remaining >= 2 ? cursor.readBigEndian() : 0
        let comment = String(data: cursor.readData(count: Int(commentLength)), encoding: encoding) ?? ""
        return Metadata(
            fileName: name,
            type: FourCharCode(rawValue: type),
            creator: FourCharCode(rawValue: creator),
            creationDate: HotlineDate.decode(baseYear: creationBaseYear, seconds: creationSeconds),
            modificationDate: HotlineDate.decode(baseYear: modificationBaseYear, seconds: modificationSeconds),
            comment: comment
        )
    }
}
