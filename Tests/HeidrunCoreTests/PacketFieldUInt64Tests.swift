import Foundation
import Testing
@testable import HeidrunCore

@Suite("PacketField UInt64")
struct PacketFieldUInt64Tests {
    @Test("round-trips a 64-bit value through write + read")
    func roundTrip() {
        let value: UInt64 = 0x0000_0001_0000_0002
        let field = PacketField.uint64(.fileSize64, value)
        #expect(field.data.count == 8)
        let decoded = [field].uint64(.fileSize64)
        #expect(decoded == value)
    }

    @Test("returns nil for a missing key")
    func missingKey() {
        let fields: [PacketField] = []
        #expect(fields.uint64(.fileSize64) == nil)
    }
}
