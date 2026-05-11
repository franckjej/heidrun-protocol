import Foundation

/// A single entry inside a server-side directory listing.
///
/// Replaces `HeiFile` from the original framework. Folders are signalled by
/// `type == FileType.folder`; alias files use `FileType.unresolvedAlias`.
///
/// `Identifiable` is satisfied by `name`, which is unique within one
/// directory listing — the only context where these values are presented
/// as a collection. Across listings IDs may collide; SwiftUI handles that
/// fine because each listing is its own view scope.
public struct RemoteFile: Sendable, Hashable, Identifiable {
    public var id: String { name }

    /// Four-character creator code.
    public var creator: FourCharCode

    /// Four-character type code. `FileType.folder` for directories.
    public var type: FourCharCode

    /// Size in bytes. For folders this is typically `0` and `itemCount`
    /// carries the entry count instead.
    public var size: UInt32

    /// Number of items inside this folder. Zero for regular files.
    public var itemCount: UInt32

    /// File name as the server reports it.
    public var name: String

    public init(
        name: String,
        type: FourCharCode = .file,
        creator: FourCharCode = .unknown,
        size: UInt32 = 0,
        itemCount: UInt32 = 0
    ) {
        self.name = name
        self.type = type
        self.creator = creator
        self.size = size
        self.itemCount = itemCount
    }

    public var isFolder: Bool { type == .folder }
    public var isUnresolvedAlias: Bool { type == .unresolvedAlias }
}

/// Wrapper around a four-byte type/creator code.
///
/// On the wire Hotline carries these as four ASCII bytes. Stored in memory as
/// `UInt32` so they compare and hash cheaply, but expose a `String`
/// representation for display.
public struct FourCharCode: Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(string: value)
    }

    /// Build from a four-character ASCII string. Strings shorter than four
    /// characters are right-padded with NUL; longer strings are truncated.
    public init(string: String) {
        var value: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        let pad = max(0, 4 - string.utf8.count)
        value <<= pad * 8
        self.rawValue = value
    }

    /// Build from exactly four bytes in big-endian order.
    public init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self.rawValue =
            (UInt32(bytes.0) << 24) |
            (UInt32(bytes.1) << 16) |
            (UInt32(bytes.2) <<  8) |
             UInt32(bytes.3)
    }

    /// ASCII representation of the code. Non-printable bytes become `.`.
    public var stringValue: String {
        let bytes: [UInt8] = (0..<4).map { i in
            UInt8(truncatingIfNeeded: rawValue >> ((3 - i) * 8))
        }
        return String(bytes: bytes.map { (32...126).contains($0) ? $0 : 0x2E }, encoding: .ascii) ?? "...."
    }

    public static let folder:           FourCharCode = "fldr"
    public static let unresolvedAlias:  FourCharCode = "alis"
    public static let file:             FourCharCode = "????"
    public static let unknown:          FourCharCode = "????"
}
