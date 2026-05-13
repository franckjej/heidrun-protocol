import Foundation
import Testing
@testable import HeidrunCore

@Suite("NewsThreadListCodec")
struct NewsThreadListCodecTests {

    /// Encode the wire format documented in `NewsThreadListCodec`, then
    /// decode it back. Exercises both single-element and zero-element
    /// paths.
    @Test("round-trips two threads with one element each")
    func roundTripsTwoThreads() {
        let payload = makeThreadListBytes(
            threads: [
                EncodedThread(
                    id: 1,
                    parent: 0,
                    baseYear: 2026,
                    secondsSinceYear: 1_000,
                    elements: [
                        EncodedElement(title: "Welcome", author: "admin", mime: "text/plain", size: 64)
                    ]
                ),
                EncodedThread(
                    id: 2,
                    parent: 1,
                    baseYear: 2026,
                    secondsSinceYear: 2_000,
                    elements: [
                        EncodedElement(title: "Re: Welcome", author: "alice", mime: "text/plain", size: 8)
                    ]
                )
            ]
        )

        let threads = NewsThreadListCodec.decode(payload)
        #expect(threads.count == 2)

        let first = try? #require(threads.first)
        #expect(first?.threadID == 1)
        #expect(first?.parentID == 0)
        #expect(first?.elements.first?.title == "Welcome")
        #expect(first?.elements.first?.author == "admin")
        #expect(first?.elements.first?.mimeType == "text/plain")
        #expect(first?.elements.first?.size == 64)

        let second = try? #require(threads.last)
        #expect(second?.threadID == 2)
        #expect(second?.parentID == 1)
        #expect(second?.elements.first?.title == "Re: Welcome")
    }

    @Test("returns an empty array when threadCount is zero")
    func emptyList() {
        let payload = makeThreadListBytes(threads: [])
        #expect(NewsThreadListCodec.decode(payload).isEmpty)
    }

    @Test("short buffer is handled defensively")
    func shortBufferReturnsEmpty() {
        #expect(NewsThreadListCodec.decode(Data([0x00])).isEmpty)
    }

    @Test("postDate round-trips through baseYear + secondsSinceYear")
    func dateRoundTrip() {
        // 2026-03-15 at exactly noon UTC = 60 days into 2026 + 12 h
        let secondsIntoYear = UInt32((73 - 1) * 86_400 + 12 * 3_600)
        let payload = makeThreadListBytes(threads: [
            EncodedThread(
                id: 1,
                parent: 0,
                baseYear: 2026,
                secondsSinceYear: secondsIntoYear,
                elements: [EncodedElement(title: "x", author: "y", mime: "text/plain", size: 0)]
            )
        ])
        let threads = NewsThreadListCodec.decode(payload)
        let date = threads.first?.postDate ?? .distantPast

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = utc.dateComponents([.year, .hour], from: date)
        #expect(components.year == 2026)
        #expect(components.hour == 12)
    }

    @Test("threadID > UInt16.max clamps to UInt16.max")
    func threadIDClamps() {
        let payload = makeThreadListBytes(threads: [
            EncodedThread(
                id: 0xFF_FF_FF_FF,
                parent: 0,
                baseYear: 2026,
                secondsSinceYear: 0,
                elements: [EncodedElement(title: "x", author: "y", mime: "text/plain", size: 1)]
            )
        ])
        let threads = NewsThreadListCodec.decode(payload)
        #expect(threads.first?.threadID == UInt16.max)
    }
}

// MARK: - Wire-format helpers

private struct EncodedThread {
    let id: UInt32
    let parent: UInt32
    let baseYear: UInt16
    let secondsSinceYear: UInt32
    let elements: [EncodedElement]
}

private struct EncodedElement {
    let title: String
    let author: String
    let mime: String
    let size: UInt16
}

private func makeThreadListBytes(threads: [EncodedThread]) -> Data {
    var data = Data()
    data.appendBigEndian(UInt32(0))
    data.appendBigEndian(UInt32(threads.count))
    data.appendBigEndian(UInt16(0))
    for thread in threads {
        data.appendBigEndian(thread.id)
        data.appendBigEndian(thread.baseYear)
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(thread.secondsSinceYear)
        data.appendBigEndian(thread.parent)
        data.appendBigEndian(UInt32(0))
        data.appendBigEndian(UInt16(thread.elements.count))
        for element in thread.elements {
            appendLengthPrefixed(element.title, into: &data)
            appendLengthPrefixed(element.author, into: &data)
            appendLengthPrefixed(element.mime, into: &data)
            data.appendBigEndian(element.size)
        }
    }
    return data
}

private func appendLengthPrefixed(_ string: String, into data: inout Data) {
    let bytes = string.data(using: .macOSRoman) ?? Data()
    let length = UInt8(min(bytes.count, 255))
    data.append(length)
    data.append(bytes.prefix(Int(length)))
}
