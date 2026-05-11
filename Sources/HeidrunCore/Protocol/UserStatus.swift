/// Single-byte status bitmask paired with a colour byte to form `hotStatus`.
///
/// Mirrors `hotStatPrivs` from the original C header. The original struct
/// numbered its bits in declaration order starting from the high bit of the
/// byte (`other2` first), which is preserved here.
public struct UserStatusFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let other2          = UserStatusFlags(rawValue: 1 << 7)
    public static let other1          = UserStatusFlags(rawValue: 1 << 6)
    public static let noPrivileges    = UserStatusFlags(rawValue: 1 << 5)
    public static let sysOp           = UserStatusFlags(rawValue: 1 << 4)
    public static let inPrivateChat   = UserStatusFlags(rawValue: 1 << 3)
    public static let hasPrivateMsg   = UserStatusFlags(rawValue: 1 << 2)
    public static let admin           = UserStatusFlags(rawValue: 1 << 1)
    public static let away            = UserStatusFlags(rawValue: 1 << 0)
}

/// Two-byte user status: a colour palette index plus a flags byte.
///
/// Mirrors `hotStatus` (`{ u_int8_t color; u_int8_t privs; }`).
public struct UserStatus: Sendable, Hashable {
    public var color: UInt8
    public var flags: UserStatusFlags

    public init(color: UInt8 = 0, flags: UserStatusFlags = []) {
        self.color = color
        self.flags = flags
    }

    /// Decode from a 16-bit value the way the original packet carries it
    /// (high byte = colour, low byte = flags).
    public init(rawValue: UInt16) {
        self.color = UInt8(truncatingIfNeeded: rawValue >> 8)
        self.flags = UserStatusFlags(rawValue: UInt8(truncatingIfNeeded: rawValue))
    }

    /// Encode back to the 16-bit field used in user-list packets.
    public var rawValue: UInt16 {
        (UInt16(color) << 8) | UInt16(flags.rawValue)
    }
}
