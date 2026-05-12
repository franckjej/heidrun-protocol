import Foundation
import Network

/// One-shot client for the Hotline tracker protocol.
///
/// A tracker (e.g. `hltracker.com:5498`) is a directory service that lists
/// currently-running Hotline servers. The protocol is intentionally simple:
/// the client opens a TCP connection, sends a 6-byte magic handshake, and
/// reads back a fixed header followed by a flat list of server entries. There
/// is no persistent session — the connection is closed once the list is read.
///
/// ## Wire format (verified against hltracker.com:5498)
///
/// **Client → Tracker (6 bytes)**
/// ```
/// 'H' 'T' 'R' 'K'   // 4-byte ASCII magic
/// 0x00 0x01          // UInt16 BE: protocol version
/// ```
///
/// **Tracker → Client**
/// ```
/// 'H' 'T' 'R' 'K'   // 4-byte echo-back magic
/// 0x00 0x01          // UInt16 BE: version echo
/// UInt16 BE          // messageType (1 = server list)
/// UInt16 BE          // payload size in bytes (rest of stream after this field)
/// UInt16 BE          // serversInThisPacket
/// UInt16 BE          // totalServers
/// ```
/// Then `serversInThisPacket` repetitions of:
/// ```
/// 4 bytes            // IPv4 in network-byte order (big-endian UInt32)
/// UInt16 BE          // port
/// UInt16 BE          // connected users
/// UInt16 BE          // unused (padding)
/// UInt8              // name length N
/// N bytes            // server name (MacRoman)
/// UInt8              // description length M
/// M bytes            // server description (MacRoman)
/// ```
public enum HotlineTrackerClient {

    // MARK: - Public API

    /// Connect to `host:port`, send the tracker handshake, and return the
    /// decoded server list. The connection is closed when this returns.
    ///
    /// - Parameters:
    ///   - host: Tracker hostname or IPv4 address (e.g. `"hltracker.com"`).
    ///   - port: Tracker port (Hotline standard is `5498`).
    ///   - stringEncoding: Encoding used for name and description strings.
    ///     Hotline defaults to `.macOSRoman`; pass `.utf8` for non-standard
    ///     trackers.
    /// - Returns: All server entries the tracker sent in a single reply.
    /// - Throws: `HotlineError.malformedReply` if the response doesn't
    ///   conform to the expected shape; network errors propagate as-is.
    public static func fetchServers(
        host: String,
        port: UInt16 = 5498,
        stringEncoding: String.Encoding = .macOSRoman
    ) async throws -> [TrackerServer] {
        let queue = DispatchQueue(label: "HotlineTrackerClient")
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HotlineError.malformedReply(reason: "invalid port \(port)")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        defer { connection.cancel() }

        try await connection.startAndWaitForReady(on: queue)
        try await connection.sendAsync(handshakeBytes)

        // --- Read and validate the 6-byte echo header ---
        let echoHeader = try await connection.receiveExactly(6)
        guard echoHeader.prefix(4) == Data(magicBytes) else {
            throw HotlineError.malformedReply(
                reason: "bad tracker magic: expected HTRK, got \(echoHeader.prefix(4).map { String(format: "%02x", $0) }.joined())"
            )
        }

        // --- Read the 8-byte message header ---
        // UInt16 messageType | UInt16 dataSize | UInt16 serversInPacket | UInt16 totalServers
        let msgHeader = try await connection.receiveExactly(8)
        var cursor = ByteCursor(data: msgHeader)
        let messageType: UInt16 = cursor.readBigEndian()
        let _: UInt16 = cursor.readBigEndian()        // dataSize — not needed; we use entry count
        let serversInPacket: UInt16 = cursor.readBigEndian()
        let _: UInt16 = cursor.readBigEndian()        // totalServers — informational only

        guard messageType == 1 else {
            throw HotlineError.malformedReply(
                reason: "unexpected tracker message type \(messageType); expected 1 (server list)"
            )
        }

        // --- Read and decode the server entries ---
        var servers: [TrackerServer] = []
        servers.reserveCapacity(Int(serversInPacket))

        for _ in 0..<serversInPacket {
            // Fixed-width prefix: ip(4) + port(2) + users(2) + unused(2) + nameLenByte(1) = 11 bytes
            let fixedHeader = try await connection.receiveExactly(11)
            var h = ByteCursor(data: fixedHeader)

            let a: UInt8 = h.readBigEndian()
            let b: UInt8 = h.readBigEndian()
            let c: UInt8 = h.readBigEndian()
            let d: UInt8 = h.readBigEndian()
            let address = "\(a).\(b).\(c).\(d)"

            let serverPort: UInt16 = h.readBigEndian()
            let users: UInt16      = h.readBigEndian()
            let _: UInt16          = h.readBigEndian()   // unused/padding
            let nameLen: UInt8     = h.readBigEndian()

            let nameData = nameLen > 0
                ? try await connection.receiveExactly(Int(nameLen))
                : Data()
            let name = String(data: nameData, encoding: stringEncoding) ?? ""

            // Description length byte
            let descLenData = try await connection.receiveExactly(1)
            let descLen = Int(descLenData[descLenData.startIndex])
            let descData = descLen > 0
                ? try await connection.receiveExactly(descLen)
                : Data()
            let description = String(data: descData, encoding: stringEncoding) ?? ""

            servers.append(TrackerServer(
                address: address,
                port: serverPort,
                users: users,
                name: name,
                description: description
            ))
        }

        return servers
    }

    // MARK: - Private constants

    private static let magicBytes: [UInt8] = [0x48, 0x54, 0x52, 0x4B]  // "HTRK"

    /// 6-byte handshake: magic "HTRK" + version 0x00 0x01
    private static let handshakeBytes = Data([
        0x48, 0x54, 0x52, 0x4B,  // "HTRK"
        0x00, 0x01               // version 1
    ])
}
