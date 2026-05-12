import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Read-only lookup of icon resources extracted from the legacy
/// `defaulthl.HeidrunIcons` package.
///
/// The build-time tool `HeidrunIconConverter` decodes the legacy NSArchiver
/// typedstream and writes one PNG per icon into `Sources/HeidrunUI/Resources/Icons/`
/// alongside an `icons.json` manifest. At runtime this catalog loads the
/// manifest once and serves images and labels by `iconID`. The shipping app
/// has no typedstream code on its hot path.
public struct IconCatalogEntry: Codable, Hashable, Sendable {
    public let id: Int
    public let label: String
    public let file: String
    public let width: Int
    public let height: Int
}

@MainActor
public final class IconCatalog {
    public static let shared = IconCatalog()

    private let entriesByID: [Int: IconCatalogEntry]
    #if canImport(AppKit)
    private var imageCache: [Int: NSImage] = [:]
    #endif
    private var cgImageCache: [Int: CGImage] = [:]
    /// IDs we've already logged as missing — prevents the same iconID from
    /// spamming the console every time it renders.
    private var loggedMissingIDs: Set<Int> = []

    private init() {
        let bundle = Bundle.module
        let manifestURL = bundle.url(forResource: "icons", withExtension: "json", subdirectory: "Icons")
            ?? bundle.url(forResource: "icons", withExtension: "json")

        guard
            let manifestURL,
            let data = try? Data(contentsOf: manifestURL),
            let entries = try? JSONDecoder().decode([IconCatalogEntry].self, from: data)
        else {
            Self.log("manifest not found in \(bundle.bundleURL.lastPathComponent); falling back to empty catalog")
            self.entriesByID = [:]
            return
        }
        self.entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let minID = entries.map(\.id).min() ?? -1
        let maxID = entries.map(\.id).max() ?? -1
        Self.log("loaded \(entries.count) entries (IDs \(minID)–\(maxID))")
    }

    nonisolated private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[IconCatalog] \(message)\n".utf8))
    }

    /// All known entries, sorted by id (stable ordering for picker UIs).
    public var allEntries: [IconCatalogEntry] {
        entriesByID.values.sorted(by: { $0.id < $1.id })
    }

    /// The display label for an icon, e.g. "Storm trooper", "Mac OS Logo".
    public func label(forID id: Int) -> String? {
        entriesByID[id]?.label
    }

    /// Returns the entry record (file name + dimensions + label) for an icon.
    public func entry(forID id: Int) -> IconCatalogEntry? {
        entriesByID[id]
    }

    /// Lazily-loaded `CGImage` for an icon, decoded directly from PNG bytes
    /// via `CGImageSource`. Cached after first read.
    ///
    /// This is the preferred path for SwiftUI consumers: `Image(decorative:
    /// scale: orientation:)` with a CGImage renders reliably across macOS
    /// versions, whereas `Image(nsImage:)` has historically had edge-case
    /// regressions where bitmap-only NSImages produce nothing on screen
    /// despite reporting the correct `size` and `representations` count.
    public func cgImage(forID id: Int) -> CGImage? {
        if let cached = cgImageCache[id] { return cached }
        guard let entry = entriesByID[id] else {
            if loggedMissingIDs.insert(id).inserted {
                Self.log("no bundled icon for ID \(id) — falling back to SF Symbol")
            }
            return nil
        }
        guard let url = bundleURL(for: entry) else {
            if loggedMissingIDs.insert(id).inserted {
                Self.log("icon ID \(id) (file \(entry.file)) — bundle URL lookup failed")
            }
            return nil
        }
        guard
            let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            if loggedMissingIDs.insert(id).inserted {
                Self.log("icon ID \(id) (file \(entry.file)) — CGImageSource decode failed")
            }
            return nil
        }
        cgImageCache[id] = cg
        return cg
    }

    private func bundleURL(for entry: IconCatalogEntry) -> URL? {
        let bundle = Bundle.module
        let pieces = entry.file.split(separator: ".", omittingEmptySubsequences: false)
        let baseName = pieces.dropLast().joined(separator: ".")
        let fileExt = pieces.last.map(String.init) ?? ""
        return bundle.url(forResource: baseName, withExtension: fileExt)
            ?? bundle.url(forResource: entry.file, withExtension: nil)
    }

    #if canImport(AppKit)
    /// Lazily-loaded NSImage for an icon. Returns `nil` when no entry exists
    /// or the PNG fails to load. Cached after first read.
    public func image(forID id: Int) -> NSImage? {
        if let cached = imageCache[id] { return cached }
        guard let entry = entriesByID[id] else {
            if loggedMissingIDs.insert(id).inserted {
                Self.log("no bundled icon for ID \(id) — falling back to SF Symbol")
            }
            return nil
        }
        let bundle = Bundle.module
        // Split filename so Bundle.url(forResource:withExtension:) finds the
        // file regardless of which subdirectory SwiftPM's .process step
        // ended up flattening it into. `icon-128.png` → name "icon-128",
        // extension "png".
        let pieces = entry.file.split(separator: ".", omittingEmptySubsequences: false)
        let baseName = pieces.dropLast().joined(separator: ".")
        let fileExt = pieces.last.map(String.init) ?? ""
        let url = bundle.url(forResource: baseName, withExtension: fileExt)
            ?? bundle.url(forResource: entry.file, withExtension: nil)
        guard let url else {
            if loggedMissingIDs.insert(id).inserted {
                Self.log("icon ID \(id) (file \(entry.file)) — bundle URL lookup failed")
            }
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            if loggedMissingIDs.insert(id).inserted {
                Self.log("icon ID \(id) (file \(entry.file)) at \(url.lastPathComponent) — NSImage failed to load")
            }
            return nil
        }
        // PNGs we generate are 16x16 pixels but NSImage may compute its
        // `size` in points based on PNG DPI metadata, which can yield
        // misleading values. Pin the size explicitly so SwiftUI's
        // Image(nsImage:) renders at native pixel dimensions when used
        // without `.resizable()`.
        image.size = NSSize(width: entry.width, height: entry.height)
        imageCache[id] = image
        return image
    }
    #endif
}
