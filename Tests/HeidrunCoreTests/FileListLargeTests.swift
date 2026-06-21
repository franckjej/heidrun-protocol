import Foundation
import Testing
@testable import HeidrunCore

@Suite("File-list large-file encoding")
struct FileListLargeTests {
    @Test("encodeLargeFile carries a 64-bit size and clamps the legacy entry")
    func encodeClampsLegacyEntry() {
        let file = RemoteFile(name: "huge.bin", size: 0x1_0000_0000)
        let (entry, size64) = FileListEntryCodec.encodeLargeFile(file)

        #expect([size64].uint64(.fileSize64) == 0x1_0000_0000)

        let decoded = FileListEntryCodec.decode(entry.data)
        #expect(decoded?.size == 0xFFFF_FFFF)
    }

    @Test("decodeList overwrites the legacy size with the trailing fileSize64")
    func decodeListUsesSize64() {
        let file = RemoteFile(name: "bigger.bin", size: 0x2_0000_0000)
        let (entry, size64) = FileListEntryCodec.encodeLargeFile(file)
        let files = FileListEntryCodec.decodeList(fields: [entry, size64])
        #expect(files.count == 1)
        #expect(files.first?.size == 0x2_0000_0000)
    }
}
