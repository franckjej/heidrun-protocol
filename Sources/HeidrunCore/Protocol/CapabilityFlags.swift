import Foundation

/// Bitmask of protocol capabilities negotiated between client and server
/// (CAPABILITY_LARGE_FILES extension). Exchanged on the wire as a UInt16
/// under `HotlineObjectKey.capabilities` (0x01F0).
public struct CapabilityFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Lift the 4 GiB transfer cap via 64-bit size fields and the 24-byte
    /// HTXF handshake variant.
    public static let largeFiles = CapabilityFlags(rawValue: 0x0001)
    /// Switch the session's string encoding from macOS Roman to UTF-8 for
    /// all traffic AFTER the (legacy-encoded) login reply. fogWraith's
    /// CAPABILITY_TEXT_ENCODING. The nickname moves out of the login packet
    /// and is sent post-login (TX 304) so it goes out in the negotiated
    /// encoding.
    public static let textEncoding = CapabilityFlags(rawValue: 0x0002)
    // Reserved (not implemented): voice 0x0004,
    // inlineMedia 0x0008, chatHistory 0x0010, extendedPriv 0x0020.

    /// The capabilities this build supports and advertises.
    public static let supported: CapabilityFlags = [.largeFiles, .textEncoding]

    /// Decide whether large-file mode is active for this session, given the
    /// `capabilities` value (field 0x01F0) the server echoed on the login
    /// reply (`nil` when the field was absent). Used by both clients to set
    /// their `largeFilesEnabled` flag after `login`.
    public static func negotiatedLargeFiles(echoed: UInt16?) -> Bool {
        CapabilityFlags(rawValue: echoed ?? 0).contains(.largeFiles)
    }

    /// Decide whether UTF-8 text encoding is active for this session, given
    /// the `capabilities` value (field 0x01F0) the server echoed on the
    /// login reply (`nil` when the field was absent). When true, both
    /// clients flip their outbound encoding (and the engine its inbound
    /// decode) to UTF-8 for all traffic after the login reply.
    public static func negotiatedTextEncoding(echoed: UInt16?) -> Bool {
        CapabilityFlags(rawValue: echoed ?? 0).contains(.textEncoding)
    }
}
