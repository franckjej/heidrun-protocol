import Foundation

/// One Hotline server-to-tracker registration packet.
///
/// Every running Hotline server periodically sends a UDP datagram to each
/// configured tracker so its name + description + live user count appear
/// in directory listings third-party clients see via
/// `HotlineTrackerClient.fetchServers(...)`. The wire format is
/// distinct from the client-to-tracker browsing handshake — different
/// transport (UDP, not TCP), different layout, no "HTRK" magic.
///
/// This struct is value-layer only; sending it is the server's job
/// (`TrackerAnnouncer` in HeidrunServerKit).
public struct TrackerRegistration: Sendable, Hashable {
    /// Wire-protocol version. Always 1 — Hotline trackers reject other
    /// values. Exposed as a public constant so the encoder and any
    /// future decoder can reference the same source of truth.
    public static let protocolVersion: UInt16 = 1

    /// Server's control-channel TCP port (typically 5500). Trackers
    /// hand this back to browsing clients so they can connect.
    public var port: UInt16

    /// Live user count at the moment the packet is built.
    public var userCount: UInt16

    /// Random per-registration nonce. Trackers use it to dedupe rapid
    /// re-registrations (e.g. server restarts inside the heartbeat
    /// window).
    public var passID: UInt32

    /// Server name shown in the tracker listing. Truncated to 255 bytes
    /// after string encoding.
    public var name: String

    /// Server description shown in the tracker listing. Same 255-byte
    /// cap as `name`.
    public var description: String

    /// Server's tracker *login*, part of the "new version" tracker
    /// format (`hldoc.txt:2488`). Empty for public trackers — but the
    /// field is still emitted as a zero-length string so a new-version
    /// tracker's parser stays byte-aligned through to the password.
    public var login: String

    /// Tracker-side password, used by private trackers that require one
    /// to accept a registration. Empty for public trackers (the common
    /// case); still emitted as a zero-length field.
    public var password: String

    public init(
        port: UInt16,
        userCount: UInt16,
        passID: UInt32,
        name: String,
        description: String,
        login: String = "",
        password: String = ""
    ) {
        self.port = port
        self.userCount = userCount
        self.passID = passID
        self.name = name
        self.description = description
        self.login = login
        self.password = password
    }
}

/// Wire codec for `TrackerRegistration`, matching the original Hotline
/// protocol's "Server Interface with Tracker" layout (`legacy/hldoc.txt`
/// in the client repo, lines 2455–2498) — *not* a third-party clone.
///
/// ## Wire format
///
/// Fixed 12-byte prefix, then the name + description, then the
/// "new version" tracker trailing fields (login + password). Every
/// string is Pascal-style (`UInt8` length + bytes) and, per the spec,
/// uses 8-bit ASCII (`hldoc.txt:2373`):
///
/// ```text
/// UInt16 BE          // protocol version, always 1
/// UInt16 BE          // server's control port
/// UInt16 BE          // user count
/// UInt16 BE          // reserved, always 0  (hldoc.txt:2468)
/// UInt32 BE          // passID — random per-registration nonce
/// UInt8              // name length N
/// N bytes            // server name (ASCII)
/// UInt8              // description length M
/// M bytes            // server description (ASCII)
/// UInt8              // login length L   (new-version trailing)
/// L bytes            // server's tracker login (ASCII, empty if public)
/// UInt8              // password length P
/// P bytes            // tracker password (ASCII, empty if public)
/// ```
///
/// The login + password fields are the spec's "new version of the
/// tracker" trailing (`hldoc.txt:2488`); modern public trackers
/// (hltracker.com, tracker.preterhuman.net, tracker.tildeverse.org)
/// expect them and reject a packet that stops after the description.
/// Each length byte caps at 255; longer values truncate silently.
public enum TrackerRegistrationCodec {
    /// Encode `registration` into a single UDP datagram payload. All
    /// strings are emitted as 8-bit ASCII per the Hotline tracker spec
    /// (`hldoc.txt:2373`).
    public static func encode(_ registration: TrackerRegistration) -> Data {
        let nameBytes = pascalBytes(registration.name)
        let descBytes = pascalBytes(registration.description)
        let loginBytes = pascalBytes(registration.login)
        let passBytes = pascalBytes(registration.password)

        var data = Data(
            capacity: 12 + nameBytes.count + descBytes.count + loginBytes.count + passBytes.count
        )
        data.appendBigEndian(TrackerRegistration.protocolVersion)
        data.appendBigEndian(registration.port)
        data.appendBigEndian(registration.userCount)
        data.appendBigEndian(UInt16(0))                 // reserved, always 0
        data.appendBigEndian(registration.passID)
        data.append(nameBytes)
        data.append(descBytes)
        data.append(loginBytes)
        data.append(passBytes)
        return data
    }

    /// `UInt8 length || bytes` Pascal-style framing in true 8-bit ASCII.
    /// Each Unicode scalar maps to its ASCII byte, or to `?` (0x3F) when
    /// it falls outside 0x00–0x7F — so the wire never carries a high-bit
    /// (e.g. MacRoman) byte. Capped at 255 bytes.
    private static func pascalBytes(_ value: String) -> Data {
        let asciiBytes = value.unicodeScalars.prefix(255).map { scalar -> UInt8 in
            scalar.value < 0x80 ? UInt8(scalar.value) : UInt8(ascii: "?")
        }
        var bytes = Data(capacity: 1 + asciiBytes.count)
        bytes.append(UInt8(asciiBytes.count))
        bytes.append(contentsOf: asciiBytes)
        return bytes
    }
}
