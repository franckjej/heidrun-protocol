import Foundation

/// Helpers the host application exposes to feature modules so they don't
/// have to reach across the connection or the AppKit boundary themselves.
///
/// Carves out the parts of the original `HeiSendingMethods` protocol that
/// were really host-side conveniences rather than wire transactions:
/// `iconForIconID:`, `getColorForPaletteID:`, and `runScriptNamed:`. The
/// original `moduleWithIdentifier:` lookup is intentionally gone: feature
/// modules are now Swift packages imported by the host and addressed by
/// type, not by string identifier.
public protocol HotlineHost: Sendable {
    /// Look up an icon from the user's currently-selected icon package.
    func icon(forID id: Int) async -> Icon?

    /// Look up the user-customised colour for a palette index. Hotline's
    /// chat palette is indexed 0–7 by convention.
    func color(forPaletteID id: Int) async -> HostColor?

    /// Run a named AppleScript file from the host's scripts folder. Returns
    /// `true` on successful execution.
    @discardableResult
    func runScript(named name: String) async -> Bool
}

/// Minimal RGB colour record exchanged between host and module.
///
/// Decoupled from `NSColor` / `CGColor` so this package stays portable to
/// non-AppKit hosts (and unit tests).
public struct HostColor: Sendable, Hashable {
    public var red:   Double
    public var green: Double
    public var blue:  Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red   = red
        self.green = green
        self.blue  = blue
        self.alpha = alpha
    }
}
