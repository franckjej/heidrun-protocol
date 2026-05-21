import Foundation
import Testing
@testable import HeidrunCore

@Suite("LongFourCC")
struct LongFourCCTests {
    @Test("encodes a four-character code as the raw four bytes")
    func encodesFourBytes() {
        let bytes = LongFourCC.encode("TEXT")
        #expect(bytes == Data([0x54, 0x45, 0x58, 0x54]))
    }
}
