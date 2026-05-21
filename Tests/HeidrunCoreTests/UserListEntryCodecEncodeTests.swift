import Foundation
import Testing
@testable import HeidrunCore

@Suite("UserListEntryCodec.encode")
struct UserListEntryCodecEncodeTests {
    @Test("round-trips a user with socket/icon/status/nickname")
    func roundTrips() {
        let user = User(
            socket: 0x1234,
            icon: 0x0042,
            status: UserStatus(rawValue: 0x0001),
            privileges: [],
            nickname: "Frank"
        )

        let field = UserListEntryCodec.encode(user, encoding: .macOSRoman)
        #expect(field.key == HotlineObjectKey.userListEntry.rawValue)

        let decoded = UserListEntryCodec.decode(field.data, encoding: .macOSRoman)
        #expect(decoded?.socket == 0x1234)
        #expect(decoded?.icon == 0x0042)
        #expect(decoded?.status.rawValue == 0x0001)
        #expect(decoded?.nickname == "Frank")
    }

    @Test("emits the exact wire byte layout for a known input")
    func goldenBytes() {
        let user = User(
            socket: 0x0102,
            icon: 0x0304,
            status: UserStatus(rawValue: 0x0506),
            privileges: [],
            nickname: "ab"
        )

        let field = UserListEntryCodec.encode(user, encoding: .ascii)
        var expected = Data()
        expected.append(contentsOf: [0x01, 0x02])             // socket
        expected.append(contentsOf: [0x03, 0x04])             // icon
        expected.append(contentsOf: [0x05, 0x06])             // status
        expected.append(contentsOf: [0x00, 0x02])             // nicknameLength
        expected.append(contentsOf: [0x61, 0x62])             // "ab"
        #expect(field.data == expected)
    }
}
