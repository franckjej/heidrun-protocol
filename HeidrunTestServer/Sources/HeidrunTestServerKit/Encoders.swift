import Foundation
import HeidrunCore

/// Wire encoders for fields the production codec only knows how to
/// decode. The real client doesn't need to emit user-list entries or
/// thread lists, so encoding lives here instead of HeidrunCore.
enum Encoders {

    /// Encode one user-list entry (object key 300).
    ///
    /// Wire layout, big-endian throughout:
    /// ```
    /// UInt16 socket
    /// UInt16 icon
    /// UInt16 status
    /// UInt16 nicknameLength
    /// UInt8  nickname[length]
    /// ```
    static func userListEntry(_ user: User, encoding: String.Encoding = .macOSRoman) -> PacketField {
        UserListEntryCodec.encode(user, encoding: encoding)
    }

    /// Encode one news-bundle entry (object key 323).
    ///
    /// Two variants per HEClientReceive.m case 323:
    /// ```
    /// UInt16 kind  (2 = bundle, 3 = category)
    /// UInt16 itemCount
    /// // kind == 2 (bundle):
    /// UInt8  nameLen
    /// UInt8  name[nameLen]
    /// UInt8  uniqueIdentifier (always 0 here)
    /// // kind == 3 (category):
    /// UInt8  identifier[16]    (zeroed; clients don't depend on it)
    /// UInt8  reserved[8]       (zero)
    /// UInt8  nameLen
    /// UInt8  name[nameLen]
    /// UInt8  reserved[3]       (zero)
    /// ```
    static func newsBundleEntry(
        name: String,
        kind: NewsBundle.Kind,
        itemCount: UInt16,
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        var data = Data()
        data.appendBE(kind.rawValue)
        data.appendBE(itemCount)

        let nameBytes = name.data(using: encoding, allowLossyConversion: true) ?? Data()
        let nameLen = UInt8(min(nameBytes.count, 255))

        switch kind {
        case .bundle:
            data.append(nameLen)
            data.append(nameBytes.prefix(Int(nameLen)))
            data.append(0)  // unique-identifier byte (unused)

        case .category:
            data.append(Data(repeating: 0, count: 16)) // 16-byte identifier
            data.append(Data(repeating: 0, count: 8))  // reserved
            data.append(nameLen)
            data.append(nameBytes.prefix(Int(nameLen)))
            data.append(Data(repeating: 0, count: 3))  // reserved trailer
        }

        return PacketField(key: HotlineObjectKey.newsBundleEntry, data: data)
    }

    /// Encode an entire news-thread list (object key 321).
    ///
    /// Wire layout matches HEClientReceive.m case 321:
    /// ```
    /// UInt32 constant (0)
    /// UInt32 threadCount
    /// UInt16 separator (0)
    /// per thread:
    ///   UInt32 threadID
    ///   UInt16 baseYear
    ///   UInt16 reserved (0)
    ///   UInt32 secondsSinceBaseYear
    ///   UInt32 parentThreadID
    ///   UInt32 constant (0)
    ///   UInt16 elementCount
    ///   per element:
    ///     UInt8  titleLen
    ///     UInt8  title[titleLen]
    ///     UInt8  authorLen
    ///     UInt8  author[authorLen]
    ///     UInt8  mimeLen
    ///     UInt8  mime[mimeLen]
    ///     UInt16 elementSize
    /// ```
    static func newsThreadList(
        _ posts: [Post],
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        var data = Data()
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(posts.count))
        data.appendBE(UInt16(0))

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let year = UInt16(calendar.component(.year, from: now))
        let startOfYear = calendar.date(from: DateComponents(year: Int(year), month: 1, day: 1)) ?? now
        let secondsSinceYear = UInt32(now.timeIntervalSince(startOfYear))

        for (index, post) in posts.enumerated() {
            data.appendBE(UInt32(index + 1))   // threadID
            data.appendBE(year)
            data.appendBE(UInt16(0))
            data.appendBE(secondsSinceYear)
            data.appendBE(UInt32(0))           // parent (top-level)
            data.appendBE(UInt32(0))           // 4-byte constant
            data.appendBE(UInt16(1))           // one element per post

            let titleBytes = post.title.data(using: encoding, allowLossyConversion: true) ?? Data()
            let authorBytes = post.author.data(using: encoding, allowLossyConversion: true) ?? Data()
            let mime = "text/plain"
            let mimeBytes = mime.data(using: .ascii) ?? Data()

            data.append(UInt8(min(titleBytes.count, 255)))
            data.append(titleBytes.prefix(255))
            data.append(UInt8(min(authorBytes.count, 255)))
            data.append(authorBytes.prefix(255))
            data.append(UInt8(min(mimeBytes.count, 255)))
            data.append(mimeBytes.prefix(255))
            let bodyBytes = post.body.data(using: encoding, allowLossyConversion: true) ?? Data()
            data.appendBE(UInt16(clamping: bodyBytes.count))
        }

        return PacketField(key: HotlineObjectKey.newsThreadList, data: data)
    }
}
