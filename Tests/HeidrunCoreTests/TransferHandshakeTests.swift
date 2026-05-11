import Foundation
import Testing
@testable import HeidrunCore

@Suite("TransferHandshake")
struct TransferHandshakeTests {
    @Test("encodes 16 bytes: HTXF + transferID + size + reserved")
    func encodes16Bytes() {
        let bytes = TransferHandshake.encode(transferID: 0x1234_ABCD, transferSize: 0)
        #expect(bytes.count == TransferHandshake.byteCount)
        #expect(Array(bytes) == [
            0x48, 0x54, 0x58, 0x46,             // "HTXF"
            0x12, 0x34, 0xAB, 0xCD,             // transferID
            0x00, 0x00, 0x00, 0x00,             // transferSize (0 for downloads)
            0x00, 0x00, 0x00, 0x00              // reserved
        ])
    }

    @Test("upload handshake carries transferSize")
    func uploadHandshake() {
        let bytes = TransferHandshake.encode(transferID: 1, transferSize: 0x0000_4000)
        let sizeBytes = Array(bytes[8..<12])
        #expect(sizeBytes == [0x00, 0x00, 0x40, 0x00])
    }
}
