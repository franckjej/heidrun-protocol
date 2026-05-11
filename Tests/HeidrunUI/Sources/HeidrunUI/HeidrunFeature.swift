import SwiftUI
import HeidrunCore

/// Static description of one feature module the SwiftUI host can list in a
/// sidebar and render in a detail pane.
///
/// In the original Heidrun a feature was a `.heimod` bundle loaded with
/// `NSBundle.principalClass`. Here every feature is a Swift library that
/// the host imports directly: `import HeidrunChat`, `import HeidrunFiles`,
/// and so on. The host pulls each feature's `.Type` into a static list,
/// reads `displayName` / `systemImage` / `identifier` for the sidebar, and
/// asks `makeContentView(client:)` to build the detail view on demand.
///
/// Conform on a caseless enum or zero-sized type — the protocol is meant to
/// be used through its metatype, not instantiated.
public protocol HeidrunFeature {
    /// Stable identifier, e.g. `"com.heidrun.chat"`. Persisted alongside
    /// user preferences (last-selected feature, custom toolbar order) so
    /// keep it stable even when `displayName` changes.
    static var identifier: String { get }

    /// Localised display name shown in the sidebar.
    static var displayName: String { get }

    /// SF Symbol name used as the sidebar icon.
    static var systemImage: String { get }

    /// Build the SwiftUI view shown in the host's detail pane while this
    /// feature is selected. The host passes the live `HotlineClient`
    /// connected to the current server.
    @MainActor
    static func makeContentView(client: any HotlineClient) -> AnyView
}
