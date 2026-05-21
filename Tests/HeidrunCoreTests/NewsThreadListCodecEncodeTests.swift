import Foundation
import Testing
@testable import HeidrunCore

@Suite("NewsThreadListCodec.encode")
struct NewsThreadListCodecEncodeTests {
    @Test("round-trips a single thread through decode")
    func singleThreadRoundTrip() {
        let postedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = NewsThreadListEntry(
            threadID: 1,
            parentID: 0,
            postedAt: postedAt,
            title: "Hello",
            author: "Frank",
            body: "world",
            mimeType: "text/plain"
        )

        let field = NewsThreadListCodec.encode([entry], encoding: .macOSRoman)
        #expect(field.key == HotlineObjectKey.newsThreadList.rawValue)

        let decoded = NewsThreadListCodec.decode(field.data, encoding: .macOSRoman)
        #expect(decoded.count == 1)
        #expect(decoded.first?.threadID == 1)
        #expect(decoded.first?.parentID == 0)
        #expect(decoded.first?.elements.count == 1)
        #expect(decoded.first?.elements.first?.title == "Hello")
        #expect(decoded.first?.elements.first?.author == "Frank")
        #expect(decoded.first?.elements.first?.mimeType == "text/plain")
        #expect(decoded.first?.elements.first?.size == UInt16("world".utf8.count))
    }

    @Test("round-trips two threads, including a non-zero parentID reply")
    func multiThreadWithParentRoundTrip() {
        let postedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [NewsThreadListEntry] = [
            NewsThreadListEntry(
                threadID: 10,
                parentID: 0,
                postedAt: postedAt,
                title: "Root",
                author: "Alice",
                body: "first",
                mimeType: "text/plain"
            ),
            NewsThreadListEntry(
                threadID: 11,
                parentID: 10,
                postedAt: postedAt,
                title: "Reply",
                author: "Bob",
                body: "second post body",
                mimeType: "text/plain"
            )
        ]

        let field = NewsThreadListCodec.encode(entries, encoding: .macOSRoman)
        let decoded = NewsThreadListCodec.decode(field.data, encoding: .macOSRoman)

        #expect(decoded.count == 2)
        #expect(decoded.first?.threadID == 10)
        #expect(decoded.first?.parentID == 0)
        #expect(decoded.last?.threadID == 11)
        #expect(decoded.last?.parentID == 10)
        #expect(decoded.last?.elements.first?.title == "Reply")
        #expect(decoded.last?.elements.first?.author == "Bob")
        #expect(decoded.last?.elements.first?.size == UInt16("second post body".utf8.count))
    }

    @Test("encodes the constant header bytes")
    func headerBytes() {
        let field = NewsThreadListCodec.encode([], encoding: .ascii)
        var expected = Data()
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // leading 4-byte constant
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // threadCount = 0
        expected.append(contentsOf: [0x00, 0x00])              // separator
        #expect(field.data == expected)
    }
}
