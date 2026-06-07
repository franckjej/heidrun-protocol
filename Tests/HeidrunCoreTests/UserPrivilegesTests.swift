import Foundation
import Testing
@testable import HeidrunCore

@Suite("UserPrivileges")
struct UserPrivilegesTests {
    @Test("encodes single privileges to the canonical MSB-first bit position")
    func singleBitPositions() {
        // Privilege N → byte N/8, bit (7 - N%8). So bit 0 is the HIGH bit of
        // byte 0 (0x80), matching classic Hotline/HXD on the wire.
        #expect(UserPrivileges.deleteFiles.bytes == [0x80, 0, 0, 0, 0, 0, 0, 0]) // bit 0
        #expect(UserPrivileges.uploadFiles.bytes == [0x40, 0, 0, 0, 0, 0, 0, 0]) // bit 1
        #expect(UserPrivileges.moveFolders.bytes == [0, 0x80, 0, 0, 0, 0, 0, 0]) // bit 8
        #expect(UserPrivileges.readUser.bytes    == [0, 0, 0x80, 0, 0, 0, 0, 0]) // bit 16
        #expect(UserPrivileges.disconnectUsers.bytes == [0, 0, 0x02, 0, 0, 0, 0, 0]) // bit 22
        #expect(UserPrivileges.canBroadcast.bytes == [0, 0, 0, 0, 0x80, 0, 0, 0]) // bit 32
        #expect(UserPrivileges.sendMessages.bytes == [0, 0, 0, 0, 0, 0x80, 0, 0]) // bit 40
    }

    @Test("decodes a real HXD guest bitmap (MacDomain) as a sensible guest")
    func decodesCanonicalHXDBitmap() {
        // Captured live from MacDomain (classic Hotline/HXD) for a guest:
        // the raw User Access (TX 354) wire bytes. Under the old LSB-first
        // order this decoded to nonsense (a "guest" with createUser +
        // canBroadcast and no chat); canonical MSB-first gives a real guest.
        let wire: [UInt8] = [0x60, 0x70, 0x0c, 0x20, 0x03, 0x80, 0x00, 0x00]
        let privs = UserPrivileges(bytes: wire)

        // Has the ordinary guest capabilities…
        #expect(privs.contains(.downloadFiles))
        #expect(privs.contains(.readChat))
        #expect(privs.contains(.sendChat))
        #expect(privs.contains(.downloadFolders))
        #expect(privs.contains(.sendMessages))
        // …and NONE of the admin/operator ones.
        #expect(!privs.contains(.createUser))
        #expect(!privs.contains(.modifyUser))
        #expect(!privs.contains(.disconnectUsers))
        #expect(!privs.contains(.canBroadcast))
    }

    @Test("round-trips through bytes representation")
    func roundTripsThroughBytes() {
        let privs: UserPrivileges = [
            .deleteFiles, .uploadFiles, .downloadFiles,
            .readChat, .sendChat,
            .readNews, .postNews,
            .canBroadcast, .sendMessages
        ]
        let restored = UserPrivileges(bytes: privs.bytes)
        #expect(restored == privs)
    }

    @Test("OptionSet semantics work as expected")
    func optionSetSemantics() {
        var privs: UserPrivileges = [.uploadFiles, .downloadFiles]
        #expect(privs.contains(.uploadFiles))
        #expect(!privs.contains(.deleteFiles))
        privs.insert(.deleteFiles)
        #expect(privs.contains(.deleteFiles))
        privs.remove(.uploadFiles)
        #expect(!privs.contains(.uploadFiles))
    }
}
