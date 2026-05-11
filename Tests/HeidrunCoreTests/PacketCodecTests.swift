import Foundation
import Testing
@testable import HeidrunCore

@Suite("PacketCodec")
struct PacketCodecTests {
    @Test("encode/decode round-trips a multi-field body")
    func roundTrip() {
        let bytes = PacketCodec.encode(
            classID: 0,
            transactionID: 107,
            taskNumber: 1,
            fields: [
                .string(.nickname, "Alice"),
                .uint16(.icon, 42),
                .obfuscatedString(.login, "tom"),
                .obfuscatedString(.password, "s3cret"),
                .uint16(.clientVersion, 151)
            ]
        )

        // Verify the header round-trips.
        let header = PacketHeader(decoding: bytes.prefix(PacketHeader.byteCount))!
        #expect(header.transactionID == 107)
        #expect(header.taskNumber == 1)
        #expect(header.dataLength > 0)

        // And the body.
        let body = bytes.suffix(from: PacketHeader.byteCount)
        let fields = PacketCodec.decodeBody(body)
        #expect(fields.count == 5)
        #expect(fields.string(.nickname) == "Alice")
        #expect(fields.uint16(.icon) == 42)
        #expect(fields.obfuscatedString(.login) == "tom")
        #expect(fields.obfuscatedString(.password) == "s3cret")
        #expect(fields.uint16(.clientVersion) == 151)
    }

    @Test("obfuscated strings invert every byte on the wire")
    func obfuscation() {
        let field = PacketField.obfuscatedString(.login, "ab")
        // 'a' = 0x61 → 0x9E,  'b' = 0x62 → 0x9D.
        #expect(Array(field.data) == [0x9E, 0x9D])
    }

    @Test("decodeBody preserves field order for repeated keys")
    func preservesOrder() {
        let bytes = PacketCodec.encode(
            classID: 0,
            transactionID: 354,
            taskNumber: 9,
            fields: [
                PacketField(key: .userListEntry, data: Data([1, 1])),
                PacketField(key: .userListEntry, data: Data([2, 2])),
                PacketField(key: .userListEntry, data: Data([3, 3]))
            ]
        )
        let body = bytes.suffix(from: PacketHeader.byteCount)
        let entries = PacketCodec
            .decodeBody(body)
            .filter { $0.key == HotlineObjectKey.userListEntry.rawValue }
        #expect(entries.map { Array($0.data) } == [[1, 1], [2, 2], [3, 3]])
    }

    @Test("UserListEntryCodec parses the hotUserList struct + nick")
    func userListEntryDecode() {
        // socket=7, icon=42, status=0x0301, nickLen=4, "Tom\0"
        var data = Data()
        data.appendBigEndian(UInt16(7))
        data.appendBigEndian(UInt16(42))
        data.appendBigEndian(UInt16(0x0301))
        data.appendBigEndian(UInt16(3))
        data.append(contentsOf: [0x54, 0x6F, 0x6D]) // "Tom"

        let user = UserListEntryCodec.decode(data, encoding: .macOSRoman)
        #expect(user?.socket == 7)
        #expect(user?.icon == 42)
        #expect(user?.status.rawValue == 0x0301)
        #expect(user?.nickname == "Tom")
    }
}
