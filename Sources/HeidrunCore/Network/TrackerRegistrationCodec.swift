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

    /// TLS sibling control port. Send 0 until TLS lands. Mobius and
    /// other modern Hotline servers advertise this so TLS-aware
    /// clients can pick the encrypted port automatically.
    public var tlsPort: UInt16

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

    /// Tracker-side password, used by private trackers that require one
    /// to accept a registration. Empty for public trackers (the common
    /// case).
    public var password: String

    public init(
        port: UInt16,
        userCount: UInt16,
        tlsPort: UInt16 = 0,
        passID: UInt32,
        name: String,
        description: String,
        password: String = ""
    ) {
        self.port = port
        self.userCount = userCount
        self.tlsPort = tlsPort
        self.passID = passID
        self.name = name
        self.description = description
        self.password = password
    }
}

/// Wire codec for `TrackerRegistration`. Mobius-compatible: the byte
/// layout matches `jhalter/mobius/hotline/tracker.go`'s
/// `TrackerRegistration.Read()` exactly.
///
/// ## Wire format
///
/// Fixed 12-byte prefix, then three Pascal-style length-prefixed
/// strings:
///
/// ```text
/// UInt16 BE          // protocol version, always 1
/// UInt16 BE          // server's control port
/// UInt16 BE          // user count
/// UInt16 BE          // TLS sibling port, 0 if no TLS
/// UInt32 BE          // passID — random per-registration nonce
/// UInt8              // name length N
/// N bytes            // server name (MacRoman)
/// UInt8              // description length M
/// M bytes            // server description (MacRoman)
/// UInt8              // password length P (0 for public trackers)
/// P bytes            // tracker-side password (MacRoman)
/// ```
///
/// Each string's length byte caps at 255; longer values truncate
/// silently — matching mobius and the broader "trackers prefer a
/// degraded entry over no entry" convention.
public enum TrackerRegistrationCodec {
    /// Encode `registration` into a single UDP datagram payload.
    /// Encoding defaults to MacRoman to stay round-trippable with
    /// legacy clients and the existing wire-format conventions.
    public static func encode(
        _ registration: TrackerRegistration,
        encoding: String.Encoding = .macOSRoman
    ) -> Data {
        let nameBytes = pascalBytes(registration.name, encoding: encoding)
        let descBytes = pascalBytes(registration.description, encoding: encoding)
        let passBytes = pascalBytes(registration.password, encoding: encoding)

        var data = Data(capacity: 12 + nameBytes.count + descBytes.count + passBytes.count)
        data.appendBigEndian(TrackerRegistration.protocolVersion)
        data.appendBigEndian(registration.port)
        data.appendBigEndian(registration.userCount)
        data.appendBigEndian(registration.tlsPort)
        data.appendBigEndian(registration.passID)
        data.append(nameBytes)
        data.append(descBytes)
        data.append(passBytes)
        return data
    }

    /// `UInt8 length || bytes` Pascal-style framing, capped at 255 bytes
    /// after the lossy encoding pass.
    private static func pascalBytes(_ value: String, encoding: String.Encoding) -> Data {
        let encoded = value.data(using: encoding, allowLossyConversion: true) ?? Data()
        let length = UInt8(min(encoded.count, 255))
        var bytes = Data(capacity: 1 + Int(length))
        bytes.append(length)
        bytes.append(encoded.prefix(Int(length)))
        return bytes
    }
}
