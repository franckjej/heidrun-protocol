import Foundation
import Testing
@testable import HeidrunCore

@Suite("PacketHeader")
struct PacketHeaderTests {
    @Test("encodes to 20 big-endian bytes")
    func encodesBigEndian() {
        let header = PacketHeader(
            classID: 0x1234,
            transactionID: 0xABCD,
            taskNumber: 0x1122_3344,
            errorID: 0xDEAD_BEEF,
            dataLength: 0x0000_0010,
            totalLength: 0x0000_0010
        )
        let bytes = header.encoded()
        #expect(bytes.count == PacketHeader.byteCount)
        #expect(Array(bytes) == [
            0x12, 0x34,             // classID
            0xAB, 0xCD,             // transactionID
            0x11, 0x22, 0x33, 0x44, // taskNumber
            0xDE, 0xAD, 0xBE, 0xEF, // errorID
            0x00, 0x00, 0x00, 0x10, // dataLength
            0x00, 0x00, 0x00, 0x10  // totalLength
        ])
    }

    @Test("round-trips through Data")
    func roundTripsThroughData() {
        let original = PacketHeader(
            classID: 1,
            transactionID: InfoTransaction.userList.rawValue,
            taskNumber: 42,
            errorID: 0,
            dataLength: 256,
            totalLength: 256
        )
        let decoded = PacketHeader(decoding: original.encoded())
        #expect(decoded == original)
    }

    @Test("rejects buffers shorter than the header")
    func shortBufferReturnsNil() {
        let truncated = Data([0x00, 0x01, 0x02])
        #expect(PacketHeader(decoding: truncated) == nil)
    }
}
