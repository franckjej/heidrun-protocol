import Foundation
import Testing
@testable import HeidrunCore

@Suite("ChatID")
struct ChatIDTests {
    @Test("byte tuple round-trips through bytes property")
    func tupleRoundTrip() {
        let id = ChatID(bytes: (0xDE, 0xAD, 0xBE, 0xEF))
        #expect(id.rawValue == 0xDEAD_BEEF)
        #expect(id.bytes == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test("Data initializer pads short input with leading zeros")
    func shortDataPadsWithZeros() {
        let id = ChatID(data: Data([0xAB, 0xCD]))
        #expect(id.bytes == [0xAB, 0xCD, 0x00, 0x00])
    }

    @Test("Data initializer truncates input longer than 4 bytes")
    func longDataTruncates() {
        let id = ChatID(data: Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))
        #expect(id.bytes == [0x11, 0x22, 0x33, 0x44])
    }

    @Test("data property and bytes property agree")
    func dataMatchesBytes() {
        let id = ChatID(rawValue: 0x0102_0304)
        #expect(Array(id.data) == id.bytes)
    }

    @Test("equal raw values produce equal IDs (Hashable holds)")
    func hashableHolds() {
        let a = ChatID(bytes: (1, 2, 3, 4))
        let b = ChatID(rawValue: 0x0102_0304)
        var set = Set<ChatID>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}
