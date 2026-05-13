import Foundation
import Testing
@testable import HeidrunCore

@Suite("Models")
struct ModelTests {
    @Test("UserStatus packs colour and flags into 16 bits")
    func userStatusRoundTrip() {
        let original = UserStatus(color: 0x07, flags: [.away, .admin])
        let restored = UserStatus(rawValue: original.rawValue)
        #expect(restored == original)
        // Byte order: high byte = colour, low byte = flags.
        #expect(original.rawValue == (UInt16(0x07) << 8) | UInt16(0b0000_0011))
    }

    @Test("FourCharCode parses ASCII strings")
    func fourCharCodeFromString() {
        let folder = FourCharCode(string: "fldr")
        #expect(folder.stringValue == "fldr")
        #expect(folder == FourCharCode.folder)
    }

    @Test("FourCharCode pads short strings with NUL")
    func fourCharCodePadding() {
        let short = FourCharCode(string: "ab")
        let bytes: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: short.rawValue >> ((3 - $0) * 8)) }
        #expect(bytes == [0x61, 0x62, 0x00, 0x00])
    }

    @Test("RemoteFile recognises folders by type code")
    func remoteFileFolderDetection() {
        let folder = RemoteFile(name: "Public", type: .folder, itemCount: 5)
        let regular = RemoteFile(name: "README.txt", type: "TEXT", size: 1024)
        #expect(folder.isFolder)
        #expect(!regular.isFolder)
    }

    @Test("AttentionFlags can combine and intersect")
    func attentionFlagsCombine() {
        let combined: AttentionFlags = [.bounceAppDockIcon, .switchToModule]
        #expect(combined.contains(.bounceAppDockIcon))
        #expect(combined.contains(.switchToModule))
        #expect(!combined.contains(.flashModuleName))
        #expect(AttentionFlags.all.contains(combined))
    }

    @Test("InfoTransaction values match the original protocol")
    func infoTransactionMatchesObjC() {
        #expect(InfoTransaction.newPost.rawValue == 102)
        #expect(InfoTransaction.userList.rawValue == 354)
        #expect(InfoTransaction.broadcast.rawValue == 355)
    }

    @Test("Reply transactions expect a reply, no-reply transactions don't")
    func transactionTypeReplyExpectation() {
        #expect(TransactionType.replyGetUserList.expectsReply)
        #expect(TransactionType.replyUploadFolder.expectsReply)
        #expect(!TransactionType.noReplySendChat.expectsReply)
        #expect(!TransactionType.noReplyMakeAlias.expectsReply)
    }

    @Test(
        "NewsCapability splits at server version 151",
        arguments: [
            (0, NewsCapability.plain),     // server didn't report a version
            (100, NewsCapability.plain),     // Hotline 1.0
            (150, NewsCapability.plain),     // Hotline 1.5.0-beta still flat
            (151, NewsCapability.threaded),  // first threaded-news build
            (185, NewsCapability.threaded),  // Hotline 1.8.5
            (200, NewsCapability.threaded)   // newer reimplementations
        ] as [(Int, NewsCapability)]
    )
    func newsCapabilityThreshold(version: Int, expected: NewsCapability) {
        #expect(NewsCapability(serverVersion: version) == expected)
    }
}
