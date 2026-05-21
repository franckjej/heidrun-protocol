import Foundation

/// Encoder for the raw 4-byte `longFileType` / `longFileCreator`
/// payloads — just the four bytes of the FourCharCode in network order.
public enum LongFourCC {
    public static func encode(_ value: FourCharCode) -> Data {
        var data = Data(capacity: 4)
        data.appendBigEndian(value.rawValue)
        return data
    }
}
