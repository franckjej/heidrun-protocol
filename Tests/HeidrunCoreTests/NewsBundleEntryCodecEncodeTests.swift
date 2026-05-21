import Foundation
import Testing
@testable import HeidrunCore

@Suite("NewsBundleEntryCodec.encode")
struct NewsBundleEntryCodecEncodeTests {
    @Test("round-trips a leaf bundle")
    func bundleRoundTrips() {
        let field = NewsBundleEntryCodec.encode(
            name: "Reads",
            kind: .bundle,
            itemCount: 7,
            encoding: .macOSRoman
        )
        #expect(field.key == HotlineObjectKey.newsBundleEntry.rawValue)

        let decoded = NewsBundleEntryCodec.decode(field.data, encoding: .macOSRoman)
        #expect(decoded?.kind == .bundle)
        #expect(decoded?.title == "Reads")
        #expect(decoded?.size == 7)
    }

    @Test("round-trips a category")
    func categoryRoundTrips() {
        let field = NewsBundleEntryCodec.encode(
            name: "Dev",
            kind: .category,
            itemCount: 0,
            encoding: .macOSRoman
        )
        #expect(field.key == HotlineObjectKey.newsBundleEntry.rawValue)

        let decoded = NewsBundleEntryCodec.decode(field.data, encoding: .macOSRoman)
        #expect(decoded?.kind == .category)
        #expect(decoded?.title == "Dev")
        #expect(decoded?.size == 0)
    }

    @Test("emits the exact wire byte layout for a bundle")
    func goldenBundleBytes() {
        let field = NewsBundleEntryCodec.encode(
            name: "Hi",
            kind: .bundle,
            itemCount: 3,
            encoding: .ascii
        )
        var expected = Data()
        expected.append(contentsOf: [0x00, 0x02])           // kind = bundle
        expected.append(contentsOf: [0x00, 0x03])           // itemCount
        expected.append(0x02)                               // nameLen
        expected.append(contentsOf: [0x48, 0x69])           // "Hi"
        expected.append(0x00)                               // trailing unique-id byte
        #expect(field.data == expected)
    }

    @Test("emits the exact wire byte layout for a category")
    func goldenCategoryBytes() {
        let field = NewsBundleEntryCodec.encode(
            name: "X",
            kind: .category,
            itemCount: 0,
            encoding: .ascii
        )
        var expected = Data()
        expected.append(contentsOf: [0x00, 0x03])               // kind = category
        expected.append(contentsOf: [0x00, 0x00])               // itemCount
        expected.append(Data(repeating: 0, count: 16))          // 16-byte identifier
        expected.append(Data(repeating: 0, count: 8))           // reserved
        expected.append(0x01)                                   // nameLen
        expected.append(0x58)                                   // "X"
        expected.append(Data(repeating: 0, count: 3))           // reserved trailer
        #expect(field.data == expected)
    }
}
