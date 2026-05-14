import Foundation

/// Decodes a `fileListEntry` blob (object key 200) into `RemoteFile`.
///
/// Wire layout (`hotFileList` from the original `HeiHLTypes.h`):
///
/// ```
/// u_int8_t  type[4]
/// u_int8_t  creator[4]
/// u_int32_t size
/// u_int32_t nrItems
/// u_int32_t nameLength
/// u_int8_t  name[nameLength]
/// ```
public enum FileListEntryCodec {
    public static func decode(
        _ data: Data,
        encoding: String.Encoding = .macOSRoman
    ) -> RemoteFile? {
        guard data.count >= 20 else { return nil }
        var cursor = ByteCursor(data: data)
        let typeBytes    = cursor.readData(count: 4)
        let creatorBytes = cursor.readData(count: 4)
        var size: UInt32 = cursor.readBigEndian()
        var itemCount: UInt32 = cursor.readBigEndian()
        let nameLength: UInt32 = cursor.readBigEndian()
        guard cursor.remaining >= Int(nameLength) else { return nil }
        let nameBytes = cursor.readData(count: Int(nameLength))
        let name = String(data: nameBytes, encoding: encoding) ?? ""

        let type = fourCharCode(from: typeBytes)
        // The legacy `hotFileList` struct exposes `size` and `nrItems`
        // as two separate UInt32s. Real Hotline 1.x servers pack a
        // folder's child count into the `size` slot and leave the
        // `nrItems` slot at 0 (production servers only fill one). Our
        // own test server fills the other slot. Normalize to a single
        // invariant — for folders, `itemCount` always carries the
        // count, regardless of which slot the server used.
        if type == .folder && itemCount == 0 && size > 0 {
            itemCount = size
            size = 0
        }

        return RemoteFile(
            name: name,
            type: type,
            creator: fourCharCode(from: creatorBytes),
            size: size,
            itemCount: itemCount
        )
    }

    private static func fourCharCode(from data: Data) -> FourCharCode {
        let bytes = Array(data.prefix(4)) + Array(repeating: UInt8(0), count: max(0, 4 - data.count))
        return FourCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
