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

    // Regression: encode/encodePrefix used to funnel the data-fork length
    // through a UInt32, trapping ("Not enough bits…") on any >4 GiB framed
    // download. The DATA fork header is the trailing 16 bytes of the prefix.
    @Test("encodePrefix carries a >4 GiB data-fork length without truncating")
    func encodePrefixLargeDataFork() {
        let dataLength: UInt64 = 0x1_0000_0000   // exactly 4 GiB
        let prefix = UploadFraming.encodePrefix(
            fileName: "huge.bin",
            type: .file,
            creator: .unknown,
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: Date(timeIntervalSince1970: 0),
            dataLength: dataLength
        )
        let header = Data(prefix.suffix(16))
        #expect(UploadFraming.forkLength(from: header) == dataLength)
    }
}
