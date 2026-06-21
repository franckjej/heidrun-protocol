import Foundation
import Testing
@testable import HeidrunCore

@Suite("HTXF large-file handshake")
struct HandshakeLargeFileTests {
    @Test("encodeLargeFile produces 24 bytes and round-trips")
    func largeFileRoundTrip() {
        let size: UInt64 = 0x0000_0001_2345_6789
        let bytes = TransferHandshake.encodeLargeFile(transferID: 7, size: size)
        #expect(bytes.count == 24)
        let parsed = TransferHandshake.parse(bytes)
        #expect(parsed?.transferID == 7)
        #expect(parsed?.size == size)
        #expect(parsed?.isLargeFile == true)
    }

    @Test("legacy 16-byte handshake parses as small, non-large file")
    func legacyParses() {
        let bytes = TransferHandshake.encode(transferID: 9, transferSize: 100)
        let parsed = TransferHandshake.parse(bytes)
        #expect(parsed?.transferID == 9)
        #expect(parsed?.size == 100)
        #expect(parsed?.isLargeFile == false)
    }
}
