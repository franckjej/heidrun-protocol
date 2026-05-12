import Foundation

/// Decoder for the `newsBundleEntry` blob (object key 323) the server
/// sends in the threaded-news reply.
///
/// Wire layout transcribed from `HEClientReceive.m` case 323 (line 395+):
///
/// ```text
/// UInt16 newsType    // 2 = bundle (leaf), 3 = category (folder)
/// UInt16 itemCount
///
/// // For newsType == 2 (bundle):
/// UInt8  nameLength
/// UInt8  name[nameLength]
/// UInt8  unique-identifier byte (ignored)
///
/// // For newsType == 3 (category):
/// UInt8  identifier[16]
/// UInt8  reserved[8]
/// UInt8  nameLength
/// UInt8  name[nameLength]
/// UInt8  reserved[3]
/// ```
public enum NewsBundleEntryCodec {
    public static func decode(
        _ data: Data,
        encoding: String.Encoding = .macOSRoman
    ) -> NewsBundle? {
        guard data.count >= 4 else { return nil }
        var cursor = ByteCursor(data: data)
        let typeRaw: UInt16 = cursor.readBigEndian()
        let count: UInt16 = cursor.readBigEndian()
        guard let kind = NewsBundle.Kind(rawValue: typeRaw) else { return nil }

        var identifier = Data()
        var name = ""

        switch kind {
        case .bundle:
            guard cursor.remaining >= 1 else { return nil }
            let length = Int(cursor.readData(count: 1).first ?? 0)
            guard cursor.remaining >= length else { return nil }
            let nameBytes = cursor.readData(count: length)
            name = String(data: nameBytes, encoding: encoding) ?? ""
            // Trailing unique-identifier byte, ignored.

        case .category:
            guard cursor.remaining >= 16 + 8 + 1 else { return nil }
            identifier = cursor.readData(count: 16)
            _ = cursor.readData(count: 8)            // ignored
            let length = Int(cursor.readData(count: 1).first ?? 0)
            guard cursor.remaining >= length else { return nil }
            let nameBytes = cursor.readData(count: length)
            name = String(data: nameBytes, encoding: encoding) ?? ""
            // Trailing 3 unknown identifier bytes, ignored.
        }

        return NewsBundle(
            identifier: identifier,
            title: name,
            kind: kind,
            size: count
        )
    }
}
