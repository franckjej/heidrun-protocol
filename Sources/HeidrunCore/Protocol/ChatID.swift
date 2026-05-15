import Foundation

/// 4-byte server-assigned identifier for a private chat.
///
/// In the original protocol the chat reference was passed around as a
/// `u_int8_t *` that callers had to remember was exactly four bytes long.
/// Fixed-size ID with a typed wrapper makes the contract explicit.
public struct ChatID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Build from the four bytes the server hands back, most-significant first.
    public init(
        _ byte0: UInt8,
        _ byte1: UInt8,
        _ byte2: UInt8,
        _ byte3: UInt8
    ) {
        self.rawValue =
            (UInt32(byte0) << 24) |
            (UInt32(byte1) << 16) |
            (UInt32(byte2) <<  8) |
             UInt32(byte3)
    }

    /// Build from a Data payload. Bytes past the fourth are ignored; bytes
    /// missing before the fourth are taken as zero.
    public init(data: Data) {
        var value: UInt32 = 0
        for byte in data.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        let pad = max(0, 4 - data.count)
        value <<= pad * 8
        self.rawValue = value
    }

    /// Big-endian byte representation for serialization.
    public var bytes: [UInt8] {
        [
            UInt8(truncatingIfNeeded: rawValue >> 24),
            UInt8(truncatingIfNeeded: rawValue >> 16),
            UInt8(truncatingIfNeeded: rawValue >>  8),
            UInt8(truncatingIfNeeded: rawValue)
        ]
    }

    public var data: Data { Data(bytes) }
}
