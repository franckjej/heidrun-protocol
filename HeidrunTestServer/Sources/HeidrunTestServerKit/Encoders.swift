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
        NewsBundleEntryCodec.encode(name: name, kind: kind, itemCount: itemCount, encoding: encoding)
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
        let now = Date()
        let entries = posts.enumerated().map { (index, post) in
            NewsThreadListEntry(
                threadID: UInt16(index + 1),
                parentID: UInt16(0),
                postedAt: now,
                title: post.title,
                author: post.author,
                body: post.body,
                mimeType: "text/plain"
            )
        }
        return NewsThreadListCodec.encode(entries, encoding: encoding)
    }
}
