import Foundation

/// One banner image delivered by a Hotline server in response to a
/// 212 (`downloadBanner`) transaction. The payload bytes arrive over
/// the HTXF side-channel with a type=2 preamble; the `kind` field
/// echoes the server's declared `BannerType` (object key 152) so the
/// client knows what to render.
///
/// `BannerKind.url` carries a UTF-8 URL string in `data` rather than
/// image bytes — the client is expected to fetch + render that URL
/// itself.
public struct ServerBanner: Sendable, Hashable {
    public enum Kind: UInt16, Sendable, Hashable {
        /// The payload bytes are a UTF-8 URL pointing at an external
        /// image — typically used by operators who host the banner
        /// on a separate CDN / web server.
        case url   = 1
        /// JPEG bytes. Decode with `NSImage(data:)` / `UIImage(data:)`.
        case jpeg  = 3
        /// GIF bytes (static or animated).
        case gif   = 4
        /// BMP bytes — uncommon in modern deployments but supported
        /// for compatibility with classic-era Hotline servers.
        case bmp   = 5
        /// QuickDraw PICT bytes. macOS dropped PICT support around
        /// 10.7; clients can detect this case + show a "format not
        /// supported" placeholder.
        case pict  = 6
    }

    public var kind: Kind
    public var data: Data

    public init(kind: Kind, data: Data) {
        self.kind = kind
        self.data = data
    }
}
