import Foundation

/// Container for either a category (a folder of bundles) or a leaf news
/// bundle that contains threads.
///
/// Replaces `HeiNewsBundle` from the original framework.
public struct NewsBundle: Sendable, Hashable, Identifiable {
    /// Distinguishes a leaf bundle from a category that groups bundles.
    public enum Kind: UInt16, Sendable, Hashable {
        case bundle   = 2
        case category = 3
    }

    /// 16-byte server-assigned identifier.
    public var identifier: Data

    public var title: String

    public var kind: Kind

    /// Reported size of the bundle in items. Servers occasionally leave it
    /// unset, so treat zero as "unknown".
    public var size: UInt16

    public init(
        identifier: Data,
        title: String = "",
        kind: Kind = .bundle,
        size: UInt16 = 0
    ) {
        self.identifier = identifier
        self.title = title
        self.kind = kind
        self.size = size
    }

    public var id: Data { identifier }
}

/// A single posted item inside a news bundle, with the elements (text,
/// attachments) attached separately.
///
/// Replaces `HeiNewsThread`. The original used `NSCalendarDate`, deprecated
/// since 10.10; we use `Date` directly.
public struct NewsThread: Sendable, Hashable, Identifiable {
    public var threadID: UInt16
    public var parentID: UInt16
    public var postDate: Date
    public var elements: [ThreadElement]

    public init(
        threadID: UInt16,
        parentID: UInt16 = 0,
        postDate: Date = Date(),
        elements: [ThreadElement] = []
    ) {
        self.threadID = threadID
        self.parentID = parentID
        self.postDate = postDate
        self.elements = elements
    }

    public var id: UInt16 { threadID }
}

/// One MIME-typed payload inside a `NewsThread`.
///
/// Replaces `HeiThreadElement`.
public struct ThreadElement: Sendable, Hashable {
    public static let plainTextType = "text/plain"

    public var title: String
    public var author: String
    public var mimeType: String
    public var size: UInt16

    public init(
        title: String = "",
        author: String = "",
        mimeType: String = ThreadElement.plainTextType,
        size: UInt16 = 0
    ) {
        self.title = title
        self.author = author
        self.mimeType = mimeType
        self.size = size
    }
}
