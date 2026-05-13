import Foundation

/// What flavour of news the connected server supports.
///
/// Hotline 1.5 (server version 151) introduced the threaded categories /
/// bundles system on top of the plain bulletin board. Earlier servers, and
/// servers that don't report a version at all (common for Wired Client and
/// other non-Apple Hotline reimplementations), only handle the plain feed.
public enum NewsCapability: Sendable, Hashable {
    /// Single appended-to text blob — `getNewsList` / `postNews` only.
    case plain
    /// Hierarchical categories → bundles → threads, plus the plain feed.
    case threaded

    /// Server versions are flat integers: 150 = 1.5.0, 185 = 1.8.5. The
    /// legacy client used `>= 151` as the threaded-news cutoff and treated
    /// a missing version as plain.
    public init(serverVersion: Int) {
        self = serverVersion >= 151 ? .threaded : .plain
    }
}

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

    /// Stable composite ID for SwiftUI list rendering.
    ///
    /// Leaf bundles (`kind == .bundle`) carry no server identifier — the
    /// wire format only includes one for categories — so using `identifier`
    /// alone collapses every leaf to the same id. Combine kind + identifier
    /// + title so siblings stay distinct even when one of the parts is
    /// empty.
    public struct ID: Hashable, Sendable {
        public let kind: Kind
        public let identifier: Data
        public let title: String
    }

    public var id: ID { ID(kind: kind, identifier: identifier, title: title) }
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
/// Replaces `HeiThreadElement`. `body` is empty in thread *listings*
/// (only metadata + size come back in the 321 blob) and populated when
/// the body is fetched explicitly via `fetchNewsThread`.
public struct ThreadElement: Sendable, Hashable {
    public static let plainTextType = "text/plain"

    public var title: String
    public var author: String
    public var mimeType: String
    public var size: UInt16
    public var body: String

    public init(
        title: String = "",
        author: String = "",
        mimeType: String = ThreadElement.plainTextType,
        size: UInt16 = 0,
        body: String = ""
    ) {
        self.title = title
        self.author = author
        self.mimeType = mimeType
        self.size = size
        self.body = body
    }
}
