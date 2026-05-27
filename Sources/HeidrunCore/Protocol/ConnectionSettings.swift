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

    /// `true` when the connection should be TLS-wrapped on the
    /// server's sibling port (5502 / +2 from the cleartext default).
    /// Defaults to `false` so old bookmarks decode to the cleartext
    /// behaviour they were saved with.
    public var useTLS: Bool

    /// Lowercase-hex SHA-256 of the server's TLS leaf certificate the
    /// user has trusted (trust-on-first-use pinning). `nil` until the
    /// user accepts a self-signed cert. Old bookmarks decode to `nil`.
    public var pinnedCertificateSHA256: String?

    /// **Heidrun extension.** UTF-8 emoji avatar the user chose for this
    /// favourite, or `nil` to use the numeric `icon`. Old bookmarks decode
    /// to `nil`.
    public var emoji: String?

    public init(
        name: String,
        address: String,
        port: UInt16 = 5500,
        nickname: String = "",
        login: String = "",
        icon: UInt16 = 0,
        useDefaultUserInfo: Bool = true,
        autoConnectFavorite: Bool = false,
        assignFavoriteShortcut: Bool = false,
        useTLS: Bool = false,
        pinnedCertificateSHA256: String? = nil,
        emoji: String? = nil
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
        self.useTLS = useTLS
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256
        self.emoji = emoji
    }

    private enum CodingKeys: String, CodingKey {
        case name, address, port, nickname, login, icon,
             useDefaultUserInfo, autoConnectFavorite,
             assignFavoriteShortcut, useTLS, pinnedCertificateSHA256, emoji
    }

    /// Hand-written decoder so v1 bookmark JSON (no `useTLS` key)
    /// loads with the `false` default rather than throwing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.address = try container.decode(String.self, forKey: .address)
        self.port = try container.decode(UInt16.self, forKey: .port)
        self.nickname = try container.decode(String.self, forKey: .nickname)
        self.login = try container.decode(String.self, forKey: .login)
        self.icon = try container.decode(UInt16.self, forKey: .icon)
        self.useDefaultUserInfo = try container.decode(Bool.self, forKey: .useDefaultUserInfo)
        self.autoConnectFavorite = try container.decode(Bool.self, forKey: .autoConnectFavorite)
        self.assignFavoriteShortcut = try container.decode(Bool.self, forKey: .assignFavoriteShortcut)
        self.useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false
        self.pinnedCertificateSHA256 = try container.decodeIfPresent(
            String.self, forKey: .pinnedCertificateSHA256)
        self.emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
    }
}
