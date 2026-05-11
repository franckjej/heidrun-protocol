import Foundation
import Testing
@testable import HeidrunCore

@Suite("UserPrivileges")
struct UserPrivilegesTests {
    @Test("encodes single privileges to the right bit position")
    func singleBitPositions() {
        #expect(UserPrivileges.deleteFiles.bytes == [0x01, 0, 0, 0, 0, 0, 0, 0])
        #expect(UserPrivileges.uploadFiles.bytes == [0x02, 0, 0, 0, 0, 0, 0, 0])
        #expect(UserPrivileges.moveFolders.bytes == [0, 0x01, 0, 0, 0, 0, 0, 0])
        #expect(UserPrivileges.readUser.bytes    == [0, 0, 0x01, 0, 0, 0, 0, 0])
        #expect(UserPrivileges.canBroadcast.bytes == [0, 0, 0, 0, 0x01, 0, 0, 0])
        #expect(UserPrivileges.sendMessages.bytes == [0, 0, 0, 0, 0, 0x01, 0, 0])
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
