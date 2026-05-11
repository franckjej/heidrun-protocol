import Foundation
import Testing
@testable import HeidrunCore

@Suite("HotlineDate")
struct HotlineDateTests {
    @Test("encode/decode round-trip with baseYear 1904")
    func roundTrip() {
        let now = Date()
        let secs = HotlineDate.encode(now)
        let decoded = HotlineDate.decode(baseYear: 1904, seconds: secs)
        // Round-trip is integer-precision; one-second tolerance covers the
        // truncation when encoding a fractional-second Date.
        let delta = abs(decoded.timeIntervalSince(now))
        #expect(delta < 1.0)
    }

    @Test("dates before 1904 clamp to 0")
    func clampsBelow() {
        let way_back = Date(timeIntervalSince1970: -3_000_000_000)
        #expect(HotlineDate.encode(way_back) == 0)
    }

    @Test("dates above UInt32.max clamp to UInt32.max")
    func clampsAbove() {
        let way_forward = Date(timeIntervalSince1970: 100_000_000_000)
        #expect(HotlineDate.encode(way_forward) == UInt32.max)
    }

    @Test("decoding 0 with baseYear 1904 gives 1904-01-01 UTC")
    func decodesEpoch() {
        let epoch = HotlineDate.decode(baseYear: 1904, seconds: 0)
        // 1904-01-01 UTC is 2_082_844_800 seconds before 1970-01-01 UTC.
        #expect(epoch.timeIntervalSince1970 == -2_082_844_800)
    }
}
