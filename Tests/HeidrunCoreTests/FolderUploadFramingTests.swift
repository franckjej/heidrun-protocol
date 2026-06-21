import Foundation
import Testing
@testable import HeidrunCore

@Suite("FolderUploadFraming + handshakes")
struct FolderUploadFramingTests {
    @Test("folder-upload handshake is 16 bytes ending in 1, 0 (UInt16s)")
    func folderUploadHandshake() {
        let bytes = TransferHandshake.encodeFolderUpload(transferID: 0xCAFE_F00D)
        #expect(bytes.count == TransferHandshake.byteCount)
        #expect(Array(bytes) == [
            0x48, 0x54, 0x58, 0x46,             // "HTXF"
            0xCA, 0xFE, 0xF0, 0x0D,             // transferID
            0x00, 0x00, 0x00, 0x00,             // transferSize 0
            0x00, 0x01, 0x00, 0x00              // UInt16 1, UInt16 0 — folder marker
        ])
    }

    @Test("folder-download handshake is 18 bytes ending in 1, 0, 3 (UInt16s)")
    func folderDownloadHandshake() {
        let bytes = TransferHandshake.encodeFolderDownload(transferID: 0xDEAD_BEEF)
        #expect(bytes.count == TransferHandshake.folderDownloadByteCount)
        #expect(Array(bytes) == [
            0x48, 0x54, 0x58, 0x46,             // "HTXF"
            0xDE, 0xAD, 0xBE, 0xEF,             // transferID
            0x00, 0x00, 0x00, 0x00,             // transferSize 0
            0x00, 0x01,                         // UInt16 1
            0x00, 0x00,                         // UInt16 0
            0x00, 0x03                          // UInt16 3 — download sentinel
        ])
    }

    @Test("item header layout: length, isDir, components")
    func itemHeaderLayout() {
        let header = FolderUploadFraming.encodeItemHeader(
            relativePath: ["sub", "file.txt"],
            isDirectory: false,
            encoding: .ascii
        )

        // First 2 bytes = payload length (everything after this field).
        var cursor = ByteCursor(data: header)
        let payloadLength: UInt16 = cursor.readBigEndian()
        #expect(Int(payloadLength) == header.count - 2)

        // Next 2 bytes = isDirectory flag.
        let isDir: UInt16 = cursor.readBigEndian()
        #expect(isDir == 0)

        // Then UInt16 component count.
        let componentCount: UInt16 = cursor.readBigEndian()
        #expect(componentCount == 2)

        // Then per component: UInt16 0 + UInt8 length + bytes.
        // First component "sub":
        let pad1: UInt16 = cursor.readBigEndian()
        #expect(pad1 == 0)
        let len1Bytes = cursor.readData(count: 1)
        #expect(len1Bytes[0] == 3)
        let name1 = cursor.readData(count: 3)
        #expect(String(data: name1, encoding: .ascii) == "sub")

        // Second component "file.txt":
        let pad2: UInt16 = cursor.readBigEndian()
        #expect(pad2 == 0)
        let len2Bytes = cursor.readData(count: 1)
        #expect(len2Bytes[0] == 8)
        let name2 = cursor.readData(count: 8)
        #expect(String(data: name2, encoding: .ascii) == "file.txt")
    }

    @Test("isDirectory flag flips to 1")
    func itemHeaderForDirectory() {
        let header = FolderUploadFraming.encodeItemHeader(
            relativePath: ["sub"],
            isDirectory: true,
            encoding: .ascii
        )
        var cursor = ByteCursor(data: header)
        _ = cursor.readBigEndian() as UInt16  // length
        let isDir: UInt16 = cursor.readBigEndian()
        #expect(isDir == 1)
    }

    @Test("legacy per-item size prefix is a 4-byte big-endian UInt32")
    func itemSizePrefixLegacy() {
        let prefix = FolderUploadFraming.encodeItemSizePrefix(0x0001_0203, largeFile: false)
        #expect(Array(prefix) == [0x00, 0x01, 0x02, 0x03])
    }

    @Test("large-file per-item size prefix is an 8-byte big-endian UInt64")
    func itemSizePrefixLargeFile() {
        // A >4 GiB total so the high word is non-zero.
        let total: UInt64 = 0x1_0000_009E
        let prefix = FolderUploadFraming.encodeItemSizePrefix(total, largeFile: true)
        #expect(Array(prefix) == [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x9E])
    }

    @Test("legacy item size prefix clamps a >4 GiB total to UInt32 max")
    func itemSizePrefixLegacyClamps() {
        let prefix = FolderUploadFraming.encodeItemSizePrefix(0x1_0000_0000, largeFile: false)
        #expect(Array(prefix) == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test("ItemAction raw values match the protocol")
    func itemActionRawValues() {
        #expect(FolderUploadFraming.ItemAction.upload.rawValue == 1)
        #expect(FolderUploadFraming.ItemAction.resume.rawValue == 2)
        #expect(FolderUploadFraming.ItemAction.skip.rawValue == 3)
        #expect(FolderUploadFraming.readyForNextItem == 3)
    }
}
