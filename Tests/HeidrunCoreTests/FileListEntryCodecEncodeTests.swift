import Foundation
import Testing
@testable import HeidrunCore

@Suite("FileListEntryCodec.encode")
struct FileListEntryCodecEncodeTests {
    @Test("encodes a file with type/creator/size/name and round-trips through decode")
    func roundTripsFile() {
        let file = RemoteFile(
            name: "readme.txt",
            type: FourCharCode(string: "TEXT"),
            creator: FourCharCode(string: "ttxt"),
            size: 1234,
            itemCount: 0
        )

        let field = FileListEntryCodec.encode(file, encoding: .macOSRoman)
        #expect(field.key == HotlineObjectKey.fileListEntry.rawValue)

        let decoded = FileListEntryCodec.decode(field.data, encoding: .macOSRoman)
        #expect(decoded?.name == "readme.txt")
        #expect(decoded?.type == FourCharCode(string: "TEXT"))
        #expect(decoded?.creator == FourCharCode(string: "ttxt"))
        #expect(decoded?.size == 1234)
        #expect(decoded?.itemCount == 0)
    }

    @Test("encodes a folder so decode normalises folder size into itemCount")
    func encodesFolderItemCount() {
        let folder = RemoteFile(
            name: "Docs",
            type: .folder,
            creator: FourCharCode(rawValue: 0),
            size: 0,
            itemCount: 7
        )

        let field = FileListEntryCodec.encode(folder, encoding: .macOSRoman)
        let decoded = FileListEntryCodec.decode(field.data, encoding: .macOSRoman)
        #expect(decoded?.type == .folder)
        #expect(decoded?.itemCount == 7)
    }

    @Test("emits the exact wire byte layout for a known input")
    func goldenBytes() {
        let file = RemoteFile(
            name: "A",
            type: FourCharCode(string: "TEXT"),
            creator: FourCharCode(string: "ttxt"),
            size: 0x01020304,
            itemCount: 0
        )

        let field = FileListEntryCodec.encode(file, encoding: .ascii)
        var expected = Data()
        expected.append(contentsOf: [0x54, 0x45, 0x58, 0x54]) // "TEXT"
        expected.append(contentsOf: [0x74, 0x74, 0x78, 0x74]) // "ttxt"
        expected.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // size
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // itemCount
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // nameLength
        expected.append(0x41)                                 // 'A'
        #expect(field.data == expected)
    }
}
