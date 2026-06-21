import Testing
@testable import HeidrunCore

@Suite("CapabilityFlags")
struct CapabilityFlagsTests {
    @Test("largeFiles is bit 0x0001")
    func largeFilesBit() {
        #expect(CapabilityFlags.largeFiles.rawValue == 0x0001)
    }

    @Test("intersection of largeFiles with itself is largeFiles")
    func intersection() {
        let lhs: CapabilityFlags = [.largeFiles]
        let rhs: CapabilityFlags = [.largeFiles]
        #expect(lhs.intersection(rhs) == [.largeFiles])
    }

    @Test("rawValue of [.largeFiles] is 1")
    func rawValue() {
        let flags: CapabilityFlags = [.largeFiles]
        #expect(flags.rawValue == 1)
    }

    @Test("negotiatedLargeFiles is true when the server echoes the bit")
    func negotiatedTrue() {
        #expect(CapabilityFlags.negotiatedLargeFiles(echoed: 0x0001))
        #expect(CapabilityFlags.negotiatedLargeFiles(echoed: 0x0003))
    }

    @Test("negotiatedLargeFiles is false when absent or unset")
    func negotiatedFalse() {
        #expect(!CapabilityFlags.negotiatedLargeFiles(echoed: nil))
        #expect(!CapabilityFlags.negotiatedLargeFiles(echoed: 0x0000))
        #expect(!CapabilityFlags.negotiatedLargeFiles(echoed: 0x0002))
    }
}
