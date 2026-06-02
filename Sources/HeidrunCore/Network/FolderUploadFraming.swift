import Foundation

/// One file or sub-directory inside a folder upload.
public struct FolderUploadItem: Sendable, Hashable {
    /// Path relative to the folder root being uploaded, ordered
    /// outer-to-inner. Last component is the file or directory name.
    public var relativePath: [String]
    public var isDirectory: Bool
    /// Empty for directories. For files this is the data fork.
    public var data: Data
    /// Empty for directories or data-fork-only files. When non-empty the
    /// bytes ride the per-item MACR block on the wire.
    public var resourceFork: Data

    public init(
        relativePath: [String],
        isDirectory: Bool,
        data: Data = Data(),
        resourceFork: Data = Data()
    ) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.data = data
        self.resourceFork = resourceFork
    }
}

/// Wire-format helpers for the per-item header that introduces every
/// item inside a folder upload.
///
/// Layout (HETransferThread.m line 821):
///
/// ```text
/// UInt16 itemHeaderLength   // bytes that follow this field
/// UInt16 isDirectory        // 0 for files, 1 for sub-directories
/// UInt16 componentCount
/// per component:
///   UInt16 reserved (0)
///   UInt8  nameLength
///   UInt8  name[nameLength]
/// ```
public enum FolderUploadFraming {

    /// Encode a single item's header.
    public static func encodeItemHeader(
        relativePath: [String],
        isDirectory: Bool,
        encoding: String.Encoding = .macOSRoman
    ) -> Data {
        // The path-encoding helper writes UInt16 count + components; reuse it.
        let pathPayload = RemotePath(components: relativePath).encoded(using: encoding)

        var payload = Data()
        payload.appendBigEndian(UInt16(isDirectory ? 1 : 0))
        payload.append(pathPayload)

        var out = Data(capacity: 2 + payload.count)
        out.appendBigEndian(UInt16(payload.count))
        out.append(payload)
        return out
    }

    /// Sentinel the server replies with after each item header. The
    /// values are not contiguous on purpose so a corrupt cast can't slip
    /// through: 1 = upload, 2 = resume, 3 = skip.
    public enum ItemAction: UInt16, Sendable, Hashable {
        case upload = 1
        case resume = 2
        case skip   = 3
    }

    /// Sentinel the server sends between items to ask for the next one.
    /// 3 means "send the next item header"; anything else means stop.
    public static let readyForNextItem: UInt16 = 3
}
