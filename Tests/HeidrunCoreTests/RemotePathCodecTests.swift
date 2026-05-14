import Foundation
import Testing
@testable import HeidrunCore

@Suite("RemotePathCodec")
struct RemotePathCodecTests {
    @Test("empty path encodes to a single 16-bit zero")
    func emptyPath() {
        let bytes = RemotePath().encoded()
        #expect(Array(bytes) == [0x00, 0x00])
    }

    @Test("path bytes follow count + (00 00, len, name) per component")
    func componentLayout() {
        let path: RemotePath = ["Drop Box", "In"]
        let bytes = path.encoded(using: .ascii)
        let expected: [UInt8] = [
            0x00, 0x02,                                // 2 components
            0x00, 0x00, 0x08,                          // pad + length(8)
            0x44, 0x72, 0x6F, 0x70, 0x20, 0x42, 0x6F, 0x78, // "Drop Box"
            0x00, 0x00, 0x02,                          // pad + length(2)
            0x49, 0x6E                                 // "In"
        ]
        #expect(Array(bytes) == expected)
    }

    @Test("FileListEntryCodec parses the hotFileList struct")
    func fileListEntryDecode() {
        var data = Data()
        data.append(contentsOf: [0x54, 0x45, 0x58, 0x54])  // type "TEXT"
        data.append(contentsOf: [0x4D, 0x41, 0x43, 0x52])  // creator "MACR"
        data.appendBigEndian(UInt32(1024))                 // size
        data.appendBigEndian(UInt32(0))                    // nrItems
        data.appendBigEndian(UInt32(8))                    // name length
        data.append(contentsOf: [
            0x52, 0x45, 0x41, 0x44, 0x4D, 0x45, 0x2E, 0x54  // "README.T"
        ])

        let file = FileListEntryCodec.decode(data, encoding: .macOSRoman)
        #expect(file?.name == "README.T")
        #expect(file?.type.stringValue == "TEXT")
        #expect(file?.creator.stringValue == "MACR")
        #expect(file?.size == 1024)
    }

    /// Real Hotline 1.x servers pack a folder's child count into the
    /// `size` slot and leave `nrItems` at 0. The decoder must surface
    /// that as `itemCount` so the UI shows "N items" instead of "0
    /// items". This was the convention observed against MacDomain.
    @Test("FileListEntryCodec moves size into itemCount for folders")
    func fileListEntryFolderWithSizeAsCount() {
        var data = Data()
        data.append(contentsOf: [0x66, 0x6C, 0x64, 0x72])  // type "fldr"
        data.append(contentsOf: [0x6E, 0x2F, 0x61, 0x20])  // creator "n/a "
        data.appendBigEndian(UInt32(7))                    // size carries the count
        data.appendBigEndian(UInt32(0))                    // nrItems (legacy slot, unused)
        data.appendBigEndian(UInt32(7))                    // name length
        data.append(contentsOf: [
            0x53, 0x70, 0x65, 0x63, 0x69, 0x61, 0x6C       // "Special"
        ])

        let entry = FileListEntryCodec.decode(data, encoding: .macOSRoman)
        #expect(entry?.isFolder == true)
        #expect(entry?.size == 0)
        #expect(entry?.itemCount == 7)
        #expect(entry?.name == "Special")
    }

    /// The reverse convention (our test server's encoding: size=0,
    /// itemCount=N) keeps working. We must not double-convert and end
    /// up clobbering an already-correct count.
    @Test("FileListEntryCodec preserves itemCount when the server fills nrItems")
    func fileListEntryFolderWithExplicitNrItems() {
        var data = Data()
        data.append(contentsOf: [0x66, 0x6C, 0x64, 0x72])  // type "fldr"
        data.append(contentsOf: [0x3F, 0x3F, 0x3F, 0x3F])  // creator unknown
        data.appendBigEndian(UInt32(0))                    // size
        data.appendBigEndian(UInt32(3))                    // nrItems
        data.appendBigEndian(UInt32(5))                    // name length
        data.append(contentsOf: [
            0x49, 0x63, 0x6F, 0x6E, 0x73                   // "Icons"
        ])

        let entry = FileListEntryCodec.decode(data, encoding: .macOSRoman)
        #expect(entry?.isFolder == true)
        #expect(entry?.size == 0)
        #expect(entry?.itemCount == 3)
    }
}
