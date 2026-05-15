import Foundation

/// A pair of URLs the download path manipulates: bytes are written to
/// `partial` while the transfer is in flight, then atomically renamed
/// to `final` on success. Naming convention is Safari-style: `report.pdf`
/// becomes `report.pdf.heidrunpart`.
public struct PartialDownloadURL: Sendable, Hashable {
    public static let suffix: String = "heidrunpart"

    public let final: URL
    public let partial: URL

    public init(finalDestination: URL) {
        self.final = finalDestination
        self.partial = finalDestination.appendingPathExtension(Self.suffix)
    }

    /// Recover the post-rename URL for a `.heidrunpart` file, or `nil`
    /// when the URL doesn't end in the suffix.
    public static func finalDestination(forPartial partial: URL) -> URL? {
        guard isPartial(partial) else { return nil }
        return partial.deletingPathExtension()
    }

    public static func isPartial(_ url: URL) -> Bool {
        url.pathExtension == suffix
    }
}
