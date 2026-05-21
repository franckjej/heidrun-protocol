import Foundation

/// Wire-format-agnostic input for `NewsThreadListCodec.encode`. One
/// value per thread row the server is about to emit. The server is
/// responsible for filling these from its own domain types; HeidrunCore
/// stays ignorant of how news is stored on disk.
public struct NewsThreadListEntry: Sendable, Hashable {
    public var threadID: UInt16
    public var parentID: UInt16
    public var postedAt: Date
    public var title: String
    public var author: String
    public var body: String
    public var mimeType: String

    public init(
        threadID: UInt16,
        parentID: UInt16 = 0,
        postedAt: Date,
        title: String,
        author: String,
        body: String,
        mimeType: String = "text/plain"
    ) {
        self.threadID = threadID
        self.parentID = parentID
        self.postedAt = postedAt
        self.title = title
        self.author = author
        self.body = body
        self.mimeType = mimeType
    }
}
