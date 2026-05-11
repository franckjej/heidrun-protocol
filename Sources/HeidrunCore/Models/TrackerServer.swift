/// One Hotline server entry returned by a tracker query.
///
/// Trackers (e.g. `hltracker.com:5498`) reply with a packed list of these
/// after the 6-byte magic + 8-byte header. `TrackerServer` is the decoded
/// value for a single entry.
public struct TrackerServer: Sendable, Hashable, Codable, Identifiable {
    /// IPv4 address in dotted-decimal notation (e.g. `"71.172.38.20"`).
    public var address: String

    /// TCP port the Hotline server listens on (typically 5500).
    public var port: UInt16

    /// Number of users currently connected to this server.
    public var users: UInt16

    /// Server display name (MacRoman encoded on the wire).
    public var name: String

    /// Short description of the server (MacRoman encoded on the wire).
    public var description: String

    /// Stable identity combining address and port.
    public var id: String { "\(address):\(port)" }

    public init(
        address: String,
        port: UInt16,
        users: UInt16,
        name: String,
        description: String
    ) {
        self.address = address
        self.port = port
        self.users = users
        self.name = name
        self.description = description
    }
}
