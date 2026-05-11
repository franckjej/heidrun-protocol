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
}
