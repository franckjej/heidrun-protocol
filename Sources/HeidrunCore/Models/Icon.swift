import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// One entry in an icon package — typically a small bitmap shown next to a
/// nickname in the user list.
///
/// Replaces `HeiIcon` from the original framework. The original held an
/// `NSImage` directly; here the image is opaque image data so the type stays
/// usable on platforms that don't link AppKit. A convenience `nsImage`
/// accessor materialises the image when AppKit is available.
public struct Icon: Sendable, Hashable, Identifiable {
    public var iconID: Int

    /// Display label, e.g. shown in the icon picker.
    public var label: String

    /// PNG- or TIFF-encoded image bytes. Nil for entries that have a label
    /// but no associated bitmap yet.
    public var imageData: Data?

    public init(iconID: Int, label: String = "", imageData: Data? = nil) {
        self.iconID = iconID
        self.label = label
        self.imageData = imageData
    }

    public var id: Int { iconID }

    #if canImport(AppKit)
    /// Materialise the image for display. Returns `nil` when no bytes are
    /// stored or the data isn't a recognised image format.
    public var nsImage: NSImage? {
        guard let imageData else { return nil }
        return NSImage(data: imageData)
    }
    #endif
}
