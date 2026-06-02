import Foundation
import Testing
@testable import HeidrunCore

@Suite("UploadFraming")
struct UploadFramingTests {
    @Test("totalSize matches the FILP+INFO+DATA+MACR breakdown")
    func totalSize() {
        // Empty file with name "x" (1 byte): info length = 74 + 1 = 75.
        // Total = 40 (FILP) + 75 (INFO) + 16 (DATA hdr) + 0 (data) + 16 (MACR hdr) = 147.
        #expect(UploadFraming.totalSize(nameLength: 1, dataLength: 0) == 147)

        // 1 KB file with 8-char name.
        // Info = 74 + 8 = 82.
        // Total = 40 + 82 + 16 + 1024 + 16 = 1178.
        #expect(UploadFraming.totalSize(nameLength: 8, dataLength: 1024) == 1178)
    }

    @Test("encoded payload starts with FILP and ends with MACR + length")
    func encodedFraming() {
        let payload = UploadFraming.encode(
            fileName: "x",
            type: "TEXT",
            creator: "MACR",
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: Date(timeIntervalSince1970: 0),
            data: Data([0xAA, 0xBB])
        )

        // FILP magic.
        #expect(Array(payload.prefix(4)) == [0x46, 0x49, 0x4C, 0x50])

        // forkCount at offset 20 should be 3.
        let forkCount = payload.subdata(in: 20..<24)
        #expect(Array(forkCount) == [0x00, 0x00, 0x00, 0x03])

        // INFO magic at offset 24.
        let infoMagic = payload.subdata(in: 24..<28)
        #expect(Array(infoMagic) == [0x49, 0x4E, 0x46, 0x4F])

        // DATA magic appears once (after FILP+INFO).
        let dataMagic = Data([0x44, 0x41, 0x54, 0x41])
        #expect(payload.firstRange(of: dataMagic) != nil)

        // MACR magic at the very end (16 bytes from end).
        let macrSlice = payload.suffix(16).prefix(4)
        #expect(Array(macrSlice) == [0x4D, 0x41, 0x43, 0x52])

        // The last 4 bytes are the resource fork length, which is 0.
        let resLen = payload.suffix(4)
        #expect(Array(resLen) == [0x00, 0x00, 0x00, 0x00])
    }

    @Test("data fork length matches the input")
    func dataLengthIsAccurate() {
        let payload = UploadFraming.encode(
            fileName: "abc",
            type: .file,
            creator: .unknown,
            creationDate: Date(),
            modificationDate: Date(),
            data: Data(repeating: 0x42, count: 100)
        )

        // Find DATA magic, then the 4-byte length is 12 bytes after it.
        let dataMagic = Data([0x44, 0x41, 0x54, 0x41])
        let dataMagicRange = payload.firstRange(of: dataMagic)!
        let lengthStart = dataMagicRange.lowerBound + 12
        let lengthBytes = payload.subdata(in: lengthStart..<lengthStart + 4)
        #expect(Array(lengthBytes) == [0x00, 0x00, 0x00, 0x64]) // 100
    }

    @Test("matches the totalSize calculation")
    func encodedSizeMatchesTotalSize() {
        let data = Data(repeating: 0x55, count: 256)
        let payload = UploadFraming.encode(
            fileName: "test.bin",
            type: .file,
            creator: .unknown,
            creationDate: Date(),
            modificationDate: Date(),
            data: data
        )
        let expected = UploadFraming.totalSize(nameLength: "test.bin".utf8.count, dataLength: 256)
        #expect(payload.count == Int(expected))
    }

    @Test("totalSize and encoded payload include the resource fork length")
    func totalSizeWithResourceFork() {
        // 1-byte name, 0-byte data, 4-byte resource fork.
        // Total = 40 + 75 + 16 + 0 + 16 + 4 = 151.
        #expect(UploadFraming.totalSize(nameLength: 1, dataLength: 0, resourceLength: 4) == 151)

        let payload = UploadFraming.encode(
            fileName: "x",
            type: "TEXT",
            creator: "ttxt",
            creationDate: Date(timeIntervalSince1970: 0),
            modificationDate: Date(timeIntervalSince1970: 0),
            data: Data(),
            resourceFork: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        #expect(payload.count == 151)

        // The MACR header is 16 bytes from the end of the data fork; the
        // resource bytes are the trailing four bytes.
        #expect(Array(payload.suffix(4)) == [0xDE, 0xAD, 0xBE, 0xEF])
        // The 4 bytes preceding the resource fork are the MACR length field
        // (big-endian UInt32 = 4).
        let lengthRange = (payload.count - 8)..<(payload.count - 4)
        #expect(Array(payload[lengthRange]) == [0x00, 0x00, 0x00, 0x04])
    }

    @Test("prefix + data + suffix(resourceFork:) reassemble the monolithic encoding")
    func chunkedPiecesWithResourceFork() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data((0..<128).map { UInt8($0 & 0xFF) })
        let rsrc = Data((0..<32).map { UInt8(($0 * 5) & 0xFF) })

        let monolithic = UploadFraming.encode(
            fileName: "split.bin",
            type: .file,
            creator: .unknown,
            creationDate: date,
            modificationDate: date,
            data: data,
            resourceFork: rsrc
        )
        let prefix = UploadFraming.encodePrefix(
            fileName: "split.bin",
            type: .file,
            creator: .unknown,
            creationDate: date,
            modificationDate: date,
            dataLength: UInt32(data.count)
        )
        let suffix = UploadFraming.encodeSuffix(resourceFork: rsrc)

        var assembled = Data()
        assembled.append(prefix)
        assembled.append(data)
        assembled.append(suffix)
        #expect(assembled == monolithic)
        #expect(suffix.count == 16 + rsrc.count)
    }

    @Test("prefix + data + suffix reassemble the monolithic encoding")
    func chunkedPiecesMatchMonolithic() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data((0..<512).map { UInt8($0 & 0xFF) })

        let monolithic = UploadFraming.encode(
            fileName: "split.bin",
            type: .file,
            creator: .unknown,
            creationDate: date,
            modificationDate: date,
            data: data
        )
        let prefix = UploadFraming.encodePrefix(
            fileName: "split.bin",
            type: .file,
            creator: .unknown,
            creationDate: date,
            modificationDate: date,
            dataLength: UInt32(data.count)
        )
        let suffix = UploadFraming.encodeSuffix()

        var assembled = Data()
        assembled.append(prefix)
        assembled.append(data)
        assembled.append(suffix)
        #expect(assembled == monolithic)
        #expect(suffix.count == 16)
        #expect(Array(suffix.prefix(4)) == [0x4D, 0x41, 0x43, 0x52])
    }
}
