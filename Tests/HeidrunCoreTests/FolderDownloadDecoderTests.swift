import Foundation
import Testing
@testable import HeidrunCore

@Suite("FolderDownloadDecoder")
struct FolderDownloadDecoderTests {
    @Test("parseItemHeader extracts isDirectory and components")
    func parseHeaderFile() {
        // folderType = 0 (even = file), 2 components ("sub", "x.txt")
        var data = Data()
        data.appendBigEndian(UInt16(0))    // folderType
        data.appendBigEndian(UInt16(2))    // componentCount
        data.appendBigEndian(UInt16(0))    // pad
        data.append(UInt8(3))              // length
        data.append(contentsOf: [0x73, 0x75, 0x62])           // "sub"
        data.appendBigEndian(UInt16(0))
        data.append(UInt8(5))
        data.append(contentsOf: [0x78, 0x2E, 0x74, 0x78, 0x74])  // "x.txt"

        let parsed = FolderDownloadDecoder.parseItemHeader(data, encoding: .ascii)
        #expect(parsed.isDirectory == false)
        #expect(parsed.components == ["sub", "x.txt"])
    }

    @Test("parseItemHeader recognises an odd folderType as a directory")
    func parseHeaderDirectory() {
        var data = Data()
        data.appendBigEndian(UInt16(1))    // folderType odd = dir
        data.appendBigEndian(UInt16(1))    // 1 component
        data.appendBigEndian(UInt16(0))    // pad
        data.append(UInt8(3))
        data.append(contentsOf: [0x73, 0x75, 0x62])  // "sub"

        let parsed = FolderDownloadDecoder.parseItemHeader(data, encoding: .ascii)
        #expect(parsed.isDirectory == true)
        #expect(parsed.components == ["sub"])
    }

    @Test("parseInfoBlock extracts metadata + name")
    func parseInfo() {
        // Build an INFO block matching the upload-side encoder for the
        // same parameters, then parse it back.
        let info = buildInfoBlock(
            type: 0x54455854,        // "TEXT"
            creator: 0x4D414352,     // "MACR"
            creBaseYear: 1904,
            creSeconds: 100,
            modBaseYear: 1904,
            modSeconds: 200,
            name: "test.txt",
            comment: "hello"
        )
        let parsed = FolderDownloadDecoder.parseInfoBlock(info, encoding: .macOSRoman)
        #expect(parsed.type == 0x54455854)
        #expect(parsed.creator == 0x4D414352)
        #expect(parsed.creBaseYear == 1904)
        #expect(parsed.creSeconds == 100)
        #expect(parsed.modSeconds == 200)
        #expect(parsed.name == "test.txt")
        #expect(parsed.comment == "hello")
    }

    @Test("encodeFileAck emits just the 2-byte download action when no resume offsets")
    func ackFreshDownload() {
        let bytes = FolderDownloadDecoder.encodeFileAck(resume: nil)
        #expect(Array(bytes) == [0x00, 0x01])

        let freshBytes = FolderDownloadDecoder.encodeFileAck(resume: ResumeInfo())
        #expect(Array(freshBytes) == [0x00, 0x01])
    }

    @Test("encodeFileAck emits action=2 + 74-byte RFLT blob when resume offsets are present")
    func ackResume() {
        let resume = ResumeInfo(dataForkOffset: 0x1000, resourceForkOffset: 0)
        let bytes = FolderDownloadDecoder.encodeFileAck(resume: resume)
        #expect(bytes.count == 2 + ResumeInfoCodec.byteCount)
        #expect(Array(bytes.prefix(2)) == [0x00, 0x02])
        // Tail is just the RFLT blob — its layout is covered by
        // ResumeInfoCodec tests; here we just confirm round-trip.
        let blob = bytes.suffix(ResumeInfoCodec.byteCount)
        #expect(ResumeInfoCodec.decode(Data(blob)) == resume)
    }

    @Test("parseInfoBlock tolerates missing comment field (UploadFraming sends 2 zero pad bytes)")
    func parseInfoNoComment() {
        // Build the exact bytes UploadFraming writes (which uses 2 trailing
        // pad bytes instead of an explicit empty comment field).
        var info = Data()
        info.append(contentsOf: [0x41, 0x4D, 0x41, 0x43])  // "AMAC"
        info.appendBigEndian(UInt32(0x54455854))
        info.appendBigEndian(UInt32(0x4D414352))
        info.append(Data(repeating: 0, count: 4))
        info.appendBigEndian(UInt32(256))
        info.append(Data(repeating: 0, count: 32))
        info.appendBigEndian(UInt16(1904))
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(UInt32(0))
        info.appendBigEndian(UInt16(1904))
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(UInt32(0))
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(UInt16(3))
        info.append(contentsOf: [0x66, 0x6F, 0x6F])  // "foo"
        info.append(Data(repeating: 0, count: 2))    // trailing pad
        let parsed = FolderDownloadDecoder.parseInfoBlock(info, encoding: .ascii)
        #expect(parsed.name == "foo")
        #expect(parsed.comment == "")
    }

    private func buildInfoBlock(
        type: UInt32,
        creator: UInt32,
        creBaseYear: UInt16,
        creSeconds: UInt32,
        modBaseYear: UInt16,
        modSeconds: UInt32,
        name: String,
        comment: String
    ) -> Data {
        var info = Data()
        info.append(contentsOf: [0x41, 0x4D, 0x41, 0x43])
        info.appendBigEndian(type)
        info.appendBigEndian(creator)
        info.append(Data(repeating: 0, count: 4))
        info.appendBigEndian(UInt32(256))
        info.append(Data(repeating: 0, count: 32))
        info.appendBigEndian(creBaseYear)
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(creSeconds)
        info.appendBigEndian(modBaseYear)
        info.append(Data(repeating: 0, count: 2))
        info.appendBigEndian(modSeconds)
        info.append(Data(repeating: 0, count: 2))
        let nameBytes = name.data(using: .macOSRoman) ?? Data()
        info.appendBigEndian(UInt16(nameBytes.count))
        info.append(nameBytes)
        let commentBytes = comment.data(using: .macOSRoman) ?? Data()
        info.appendBigEndian(UInt16(commentBytes.count))
        info.append(commentBytes)
        return info
    }
}
