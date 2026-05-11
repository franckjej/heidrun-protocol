/// User-chosen connection details exposed by the host application to its
/// modules.
///
/// Replaces the loose `NSDictionary` returned by `HeiSendingMethods
/// -connectionSettings`. The original keys live on as the property names so
/// nothing semantic changes; only the typing tightens.
public struct ConnectionSettings: Sendable, Hashable, Codable {
    /// Friendly name the user gave this favourite (e.g. "Tom's BBS").
    public var name: String

    /// Hostname or IP the favourite resolves to.
    public var address: String

    /// TCP port — Hotline servers default to 5500.
    public var port: UInt16

    /// Nickname the user wants to log in with.
    public var nickname: String

    /// Server-side login name. Empty for guest connections. Stored in
    /// bookmarks/recents alongside the rest of the connection identity.
    public var login: String

    /// Icon ID from the user's selected icon package.
    public var icon: UInt16

    /// `true` when the host is using its application-wide default user info
    /// instead of the favourite's own values.
    public var useDefaultUserInfo: Bool

    /// `true` when this favourite should be auto-connected at app launch.
    public var autoConnectFavorite: Bool

    /// `true` when a keyboard shortcut should be auto-assigned.
    public var assignFavoriteShortcut: Bool

    public init(
        name: String,
        address: String,
        port: UInt16 = 5500,
        nickname: String = "",
        login: String = "",
        icon: UInt16 = 0,
        useDefaultUserInfo: Bool = true,
        autoConnectFavorite: Bool = false,
        assignFavoriteShortcut: Bool = false
    ) {
        self.name = name
        self.address = address
        self.port = port
        self.nickname = nickname
        self.login = login
        self.icon = icon
        self.useDefaultUserInfo = useDefaultUserInfo
        self.autoConnectFavorite = autoConnectFavorite
        self.assignFavoriteShortcut = assignFavoriteShortcut
    }
}
