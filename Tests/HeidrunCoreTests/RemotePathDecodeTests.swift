import Foundation
import Testing
@testable import HeidrunCore

@Suite("RemotePath decode")
struct RemotePathDecodeTests {
    @Test("round-trips a two-component path through encode/decode")
    func roundTrips() throws {
        let original = RemotePath(components: ["folder", "category"])
        let bytes = original.encoded(using: .macOSRoman)
        let decoded = try #require(RemotePath(decoding: bytes, encoding: .macOSRoman))
        #expect(decoded == original)
    }

    @Test("returns nil on truncated input")
    func rejectsTruncated() {
        let bytes = Data([0x00, 0x01, 0x00, 0x00, 0x05, 0x61])
        #expect(RemotePath(decoding: bytes, encoding: .macOSRoman) == nil)
    }
}
