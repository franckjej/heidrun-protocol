/// Per-user permission bitmask carried in `User.privileges`.
///
/// On the wire the original `hotUserPrivs` struct is exactly 8 bytes, with
/// each privilege occupying one bit. Bit 0 of byte 0 in the original C
/// struct is `deleteFiles`, bit 1 is `uploadFiles`, and so on. The bit
/// numbering here matches that layout so packets round-trip cleanly.
public struct UserPrivileges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    // Byte 0
    public static let deleteFiles         = UserPrivileges(rawValue: 1 <<  0)
    public static let uploadFiles         = UserPrivileges(rawValue: 1 <<  1)
    public static let downloadFiles       = UserPrivileges(rawValue: 1 <<  2)
    public static let renameFiles         = UserPrivileges(rawValue: 1 <<  3)
    public static let moveFiles           = UserPrivileges(rawValue: 1 <<  4)
    public static let createFolders       = UserPrivileges(rawValue: 1 <<  5)
    public static let deleteFolders       = UserPrivileges(rawValue: 1 <<  6)
    public static let renameFolders       = UserPrivileges(rawValue: 1 <<  7)

    // Byte 1
    public static let moveFolders         = UserPrivileges(rawValue: 1 <<  8)
    public static let readChat            = UserPrivileges(rawValue: 1 <<  9)
    public static let sendChat            = UserPrivileges(rawValue: 1 << 10)
    public static let initiatePrivateChat = UserPrivileges(rawValue: 1 << 11)
    public static let closePrivateChat    = UserPrivileges(rawValue: 1 << 12)
    public static let showInList          = UserPrivileges(rawValue: 1 << 13)
    public static let createUser          = UserPrivileges(rawValue: 1 << 14)
    public static let deleteUser          = UserPrivileges(rawValue: 1 << 15)

    // Byte 2
    public static let readUser            = UserPrivileges(rawValue: 1 << 16)
    public static let modifyUser          = UserPrivileges(rawValue: 1 << 17)
    public static let changeOwnPassword   = UserPrivileges(rawValue: 1 << 18)
    public static let readNews            = UserPrivileges(rawValue: 1 << 20)
    public static let postNews            = UserPrivileges(rawValue: 1 << 21)
    public static let disconnectUsers     = UserPrivileges(rawValue: 1 << 22)
    public static let cannotBeDisconnected = UserPrivileges(rawValue: 1 << 23)

    // Byte 3
    public static let getUserInfo         = UserPrivileges(rawValue: 1 << 24)
    public static let uploadAnywhere      = UserPrivileges(rawValue: 1 << 25)
    public static let useAnyName          = UserPrivileges(rawValue: 1 << 26)
    public static let dontShowAgreement   = UserPrivileges(rawValue: 1 << 27)
    public static let commentFiles        = UserPrivileges(rawValue: 1 << 28)
    public static let commentFolders      = UserPrivileges(rawValue: 1 << 29)
    public static let viewDropBoxes       = UserPrivileges(rawValue: 1 << 30)
    public static let makeAliases         = UserPrivileges(rawValue: 1 << 31)

    // Byte 4
    public static let canBroadcast        = UserPrivileges(rawValue: 1 << 32)
    public static let deleteArticles      = UserPrivileges(rawValue: 1 << 33)
    public static let createCategories    = UserPrivileges(rawValue: 1 << 34)
    public static let deleteCategories    = UserPrivileges(rawValue: 1 << 35)
    public static let createNewsBundles   = UserPrivileges(rawValue: 1 << 36)
    public static let deleteNewsBundles   = UserPrivileges(rawValue: 1 << 37)
    public static let uploadFolders       = UserPrivileges(rawValue: 1 << 38)
    public static let downloadFolders     = UserPrivileges(rawValue: 1 << 39)

    // Byte 5
    public static let sendMessages        = UserPrivileges(rawValue: 1 << 40)

    /// Every defined privilege bit OR'd together. Use to seed a
    /// super-admin account that should be able to perform every
    /// operation the protocol exposes.
    public static let all: UserPrivileges = [
        .deleteFiles, .uploadFiles, .downloadFiles, .renameFiles, .moveFiles,
        .createFolders, .deleteFolders, .renameFolders, .moveFolders,
        .readChat, .sendChat, .initiatePrivateChat, .closePrivateChat,
        .showInList, .createUser, .deleteUser, .readUser, .modifyUser,
        .changeOwnPassword, .readNews, .postNews, .disconnectUsers,
        .cannotBeDisconnected, .getUserInfo, .uploadAnywhere, .useAnyName,
        .dontShowAgreement, .commentFiles, .commentFolders, .viewDropBoxes,
        .makeAliases, .canBroadcast, .deleteArticles, .createCategories,
        .deleteCategories, .createNewsBundles, .deleteNewsBundles,
        .uploadFolders, .downloadFolders, .sendMessages
    ]

    /// Decode an 8-byte privilege blob from a Hotline packet.
    public init(bytes: some Sequence<UInt8>) {
        var value: UInt64 = 0
        var byteIndex = 0
        for byte in bytes where byteIndex < 8 {
            value |= UInt64(byte) << (byteIndex * 8)
            byteIndex += 1
        }
        self.rawValue = value
    }

    /// Encode to the 8-byte representation expected on the wire.
    public var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: rawValue >> ($0 * 8)) }
    }
}
