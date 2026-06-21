import Testing
@testable import HeidrunCore

@Suite("Large-file object keys")
struct CapabilityKeyTests {
    @Test("rawValues match the wire spec")
    func rawValues() {
        #expect(HotlineObjectKey.capabilities.rawValue == 0x01F0)
        #expect(HotlineObjectKey.fileSize64.rawValue == 0x01F1)
        #expect(HotlineObjectKey.offset64.rawValue == 0x01F2)
        #expect(HotlineObjectKey.xferSize64.rawValue == 0x01F3)
        #expect(HotlineObjectKey.folderItemCount64.rawValue == 0x01F4)
    }
}
