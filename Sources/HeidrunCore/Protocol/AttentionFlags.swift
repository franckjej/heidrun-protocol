/// Bit field passed to `requestAttentionOfType:module:` on the host client to
/// describe how a module wants to alert the user about new activity.
///
/// The original C macros `kBounceAppDockIcon` etc. each occupied a different
/// byte of a 32-bit mask. The byte layout is preserved so that an existing
/// host that still expects the old bit positions keeps working.
public struct AttentionFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Bounce this app's Dock icon.
    public static let bounceAppDockIcon = AttentionFlags(rawValue: 0x0000_00FF)

    /// Force this app to become the front-most application.
    public static let forceAppChange    = AttentionFlags(rawValue: 0x0000_FF00)

    /// Switch the active module inside the host window to the requesting one.
    public static let switchToModule    = AttentionFlags(rawValue: 0x00FF_0000)

    /// Flash the requesting module's tab/label in the host UI.
    public static let flashModuleName   = AttentionFlags(rawValue: 0xFF00_0000)

    /// Convenience covering every documented attention bit.
    public static let all: AttentionFlags = [
        .bounceAppDockIcon,
        .forceAppChange,
        .switchToModule,
        .flashModuleName
    ]
}
