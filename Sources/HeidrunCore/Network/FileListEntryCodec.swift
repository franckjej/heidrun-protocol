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
        let size: UInt32 = cursor.readBigEndian()
        let itemCount: UInt32 = cursor.readBigEndian()
        let nameLength: UInt32 = cursor.readBigEndian()
        guard cursor.remaining >= Int(nameLength) else { return nil }
        let nameBytes = cursor.readData(count: Int(nameLength))
        let name = String(data: nameBytes, encoding: encoding) ?? ""

        return RemoteFile(
            name: name,
            type: fourCharCode(from: typeBytes),
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
