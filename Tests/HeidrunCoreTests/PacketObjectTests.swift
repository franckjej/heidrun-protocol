import Foundation
import Testing
@testable import HeidrunCore

@Suite("PacketObject")
struct PacketObjectTests {
    @Test("encodes id, length, and body in big-endian order")
    func encodesBigEndian() {
        let body = Data([0x10, 0x20, 0x30])
        let object = PacketObject(objectID: 0x00FF, data: body)
        let bytes = object.encoded()
        #expect(Array(bytes) == [0x00, 0xFF, 0x00, 0x03, 0x10, 0x20, 0x30])
    }

    @Test("round-trips through ByteCursor")
    func roundTripsThroughCursor() {
        let first  = PacketObject(objectID: 1, data: Data("hello".utf8))
        let second = PacketObject(objectID: 2, data: Data("world!".utf8))
        var stream = Data()
        stream.append(first.encoded())
        stream.append(second.encoded())

        var cursor = ByteCursor(data: stream)
        let decodedFirst  = PacketObject.decode(from: &cursor)
        let decodedSecond = PacketObject.decode(from: &cursor)

        #expect(decodedFirst == first)
        #expect(decodedSecond == second)
        #expect(cursor.isAtEnd)
    }

    @Test("returns nil when the body is truncated")
    func truncatedBodyReturnsNil() {
        // Header claims 4 bytes of body but only 2 are present.
        let truncated = Data([0x00, 0x01, 0x00, 0x04, 0xAA, 0xBB])
        var cursor = ByteCursor(data: truncated)
        #expect(PacketObject.decode(from: &cursor) == nil)
    }
}
