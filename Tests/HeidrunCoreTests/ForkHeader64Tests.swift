import Foundation
import Testing
@testable import HeidrunCore

@Suite("64-bit FFO fork headers")
struct ForkHeader64Tests {
    @Test("forkHeader is 16 bytes and forkLength recovers a 64-bit length")
    func roundTrip() {
        let length: UInt64 = 0x0000_0002_ABCD_EF01
        let header = UploadFraming.forkHeader(magic: "DATA", length: length)
        #expect(header.count == 16)
        #expect(UploadFraming.forkLength(from: header) == length)
    }

    @Test("small lengths emit byte-identical legacy headers")
    func legacyByteIdentical() {
        let header = UploadFraming.forkHeader(magic: "DATA", length: 100)
        var expected = Data([0x44, 0x41, 0x54, 0x41])
        expected.append(Data(repeating: 0, count: 8))
        expected.appendBigEndian(UInt32(100))
        #expect(header == expected)
    }
}
