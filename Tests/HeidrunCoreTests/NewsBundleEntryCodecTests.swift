import Foundation
import Testing
@testable import HeidrunCore

@Suite("NewsBundleEntryCodec")
struct NewsBundleEntryCodecTests {
    @Test("decodes a leaf bundle (newsType = 2)")
    func decodesBundle() {
        var data = Data()
        data.appendBigEndian(UInt16(2))            // newsType = bundle
        data.appendBigEndian(UInt16(7))            // itemCount
        data.append(UInt8(5))                      // nameLength
        data.append(contentsOf: [0x52, 0x65, 0x61, 0x64, 0x73])  // "Reads"
        data.append(UInt8(0))                      // unique-identifier byte (ignored)

        let bundle = NewsBundleEntryCodec.decode(data, encoding: .ascii)
        #expect(bundle?.kind == .bundle)
        #expect(bundle?.title == "Reads")
        #expect(bundle?.size == 7)
        #expect(bundle?.identifier.isEmpty == true)
    }

    @Test("decodes a category (newsType = 3) and stores the 16-byte identifier")
    func decodesCategory() {
        var data = Data()
        data.appendBigEndian(UInt16(3))            // newsType = category
        data.appendBigEndian(UInt16(0))            // itemCount
        let identifier = Data((0..<16).map { UInt8($0 + 0x10) })
        data.append(identifier)                    // 16 bytes identifier
        data.append(Data(repeating: 0, count: 8))  // 8 ignored bytes
        data.append(UInt8(3))                      // nameLength
        data.append(contentsOf: [0x44, 0x65, 0x76]) // "Dev"
        data.append(Data(repeating: 0, count: 3))  // 3 trailing ignored bytes

        let bundle = NewsBundleEntryCodec.decode(data, encoding: .ascii)
        #expect(bundle?.kind == .category)
        #expect(bundle?.title == "Dev")
        #expect(bundle?.identifier == identifier)
    }

    @Test("returns nil for unknown newsType")
    func unknownTypeReturnsNil() {
        var data = Data()
        data.appendBigEndian(UInt16(99))
        data.appendBigEndian(UInt16(0))
        #expect(NewsBundleEntryCodec.decode(data) == nil)
    }
}
