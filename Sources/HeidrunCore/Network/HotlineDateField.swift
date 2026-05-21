import Foundation

/// Encoder for the 8-byte Hotline date field used by file-info,
/// account-creation, and several news transactions. Always emits
/// baseYear = 1904.
public enum HotlineDateField {
    public static func encode(_ date: Date, key: HotlineObjectKey) -> PacketField {
        var data = Data(capacity: 8)
        data.appendBigEndian(UInt16(1904))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(HotlineDate.encode(date))
        return PacketField(key: key, data: data)
    }
}
