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
        let size32: UInt32 = cursor.readBigEndian()
        var size: UInt64 = UInt64(size32)
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
            itemCount = size32
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

    /// Encode a `RemoteFile` as the body bytes for a `fileListEntry` object (key 200).
    public static func encode(
        _ file: RemoteFile,
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        var data = Data(capacity: 20 + file.name.count)
        data.appendBigEndian(file.type.rawValue)
        data.appendBigEndian(file.creator.rawValue)
        data.appendBigEndian(UInt32(clamping: file.size))
        data.appendBigEndian(file.itemCount)
        let nameBytes = file.name.data(using: encoding, allowLossyConversion: true) ?? Data()
        data.appendBigEndian(UInt32(clamping: nameBytes.count))
        data.append(nameBytes)
        return PacketField(key: HotlineObjectKey.fileListEntry, data: data)
    }

    /// Encode a `RemoteFile` for the large-file dialect: the legacy entry
    /// (size clamped to 32 bits) plus a companion `fileSize64` field
    /// carrying the true 64-bit size.
    public static func encodeLargeFile(
        _ file: RemoteFile,
        encoding: String.Encoding = .macOSRoman
    ) -> (entry: PacketField, size64: PacketField) {
        let entry = encode(file, encoding: encoding)
        let size64 = PacketField.uint64(.fileSize64, file.size)
        return (entry, size64)
    }

    /// Decode an ordered list of fields into `RemoteFile`s. When a
    /// `fileListEntry` is immediately followed by a `fileSize64` field,
    /// the decoded file's `size` is overwritten with the 64-bit value.
    public static func decodeList(
        fields: [PacketField],
        encoding: String.Encoding = .macOSRoman
    ) -> [RemoteFile] {
        var result: [RemoteFile] = []
        var index = fields.startIndex
        while index < fields.endIndex {
            let field = fields[index]
            guard field.key == HotlineObjectKey.fileListEntry.rawValue,
                  var file = decode(field.data, encoding: encoding) else {
                index = fields.index(after: index)
                continue
            }
            let nextIndex = fields.index(after: index)
            if nextIndex < fields.endIndex,
               fields[nextIndex].key == HotlineObjectKey.fileSize64.rawValue,
               let size64 = [fields[nextIndex]].uint64(.fileSize64) {
                file.size = size64
                index = fields.index(after: nextIndex)
            } else {
                index = nextIndex
            }
            result.append(file)
        }
        return result
    }

    private static func fourCharCode(from data: Data) -> FourCharCode {
        let bytes = Array(data.prefix(4)) + Array(repeating: UInt8(0), count: max(0, 4 - data.count))
        return FourCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
