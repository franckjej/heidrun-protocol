import Foundation
import Testing
@testable import HeidrunCore

@Suite("ResumeInfoCodec")
struct ResumeInfoCodecTests {
    @Test("encode produces 74 bytes with the right magic + offsets")
    func encodeLayout() {
        let bytes = ResumeInfoCodec.encode(
            ResumeInfo(dataForkOffset: 0x0000_1000, resourceForkOffset: 0x0000_0020)
        )
        #expect(bytes.count == ResumeInfoCodec.byteCount)
        // "RFLT" at offset 0
        #expect(Array(bytes.prefix(4)) == [0x52, 0x46, 0x4C, 0x54])
        // UInt16 1 at offset 4
        #expect(Array(bytes[4..<6]) == [0x00, 0x01])
        // UInt16 2 at offset 40
        #expect(Array(bytes[40..<42]) == [0x00, 0x02])
        // "DATA" at offset 42
        #expect(Array(bytes[42..<46]) == [0x44, 0x41, 0x54, 0x41])
        // dataForkOffset at offset 46 (big-endian)
        #expect(Array(bytes[46..<50]) == [0x00, 0x00, 0x10, 0x00])
        // "MACR" at offset 58
        #expect(Array(bytes[58..<62]) == [0x4D, 0x41, 0x43, 0x52])
        // resourceForkOffset at offset 62
        #expect(Array(bytes[62..<66]) == [0x00, 0x00, 0x00, 0x20])
    }

    @Test("round-trips through decode")
    func roundTrip() {
        let original = ResumeInfo(
            dataForkOffset: 12_345_678,
            resourceForkOffset: 90
        )
        let restored = ResumeInfoCodec.decode(ResumeInfoCodec.encode(original))
        #expect(restored == original)
    }

    @Test("decode returns nil for short input")
    func tooShort() {
        #expect(ResumeInfoCodec.decode(Data(repeating: 0, count: 10)) == nil)
    }

    @Test("isFresh distinguishes the no-resume case")
    func isFreshFlag() {
        #expect(ResumeInfo().isFresh)
        #expect(!ResumeInfo(dataForkOffset: 1).isFresh)
        #expect(!ResumeInfo(resourceForkOffset: 1).isFresh)
    }
}
