import Foundation
import Testing
@testable import HeidrunCore

/// Feeds a byte tape to `FlattenedFileStream.decode` through the
/// read-exactly closure and records how many bytes were requested, so a
/// test can prove the decoder never reads past the last fork.
private final class ByteTape: @unchecked Sendable {
    private let bytes: Data
    private(set) var consumed = 0

    init(_ bytes: Data) { self.bytes = bytes }

    func readExactly(_ count: Int) throws -> Data {
        guard consumed + count <= bytes.count else { throw UploadFraming.DecodeError.truncated }
        let slice = bytes[(bytes.startIndex + consumed)..<(bytes.startIndex + consumed + count)]
        consumed += count
        return Data(slice)
    }
}

@Suite("FlattenedFileStream — streaming FILP decode")
struct FlattenedFileStreamTests {

    @Test("a classic two-fork envelope yields the data fork and nothing past it")
    func classicTwoForkEnvelope() async throws {
        let payload = Data("PK\u{03}\u{04} zip bytes".utf8)
        let envelope = classicEnvelope(name: "Icons 2014.zip", type: "ZIP ", creator: "SITx", data: payload)
        // A trailing garbage byte proves the decoder stops at the last fork
        // instead of trusting any outer byte count.
        let tape = ByteTape(envelope + Data([0xFF]))

        var received = Data()
        let result = try await FlattenedFileStream.decode(
            readExactly: { try tape.readExactly($0) },
            encoding: .macOSRoman,
            onData: { received.append($0) }
        )

        #expect(received == payload)
        #expect(result.resourceFork.isEmpty)
        #expect(result.metadata.fileName == "Icons 2014.zip")
        #expect(result.metadata.type == "ZIP ")
        #expect(result.metadata.creator == "SITx")
        #expect(tape.consumed == envelope.count)
    }

    @Test("a three-fork envelope surfaces the MACR resource fork")
    func threeForkEnvelope() async throws {
        let payload = Data((0..<300).map { UInt8($0 & 0xFF) })
        let resource = Data((0..<64).map { UInt8(($0 * 5) & 0xFF) })
        let envelope = UploadFraming.encode(
            fileName: "icon.icns", type: "icns", creator: "ttxt",
            creationDate: Date(), modificationDate: Date(),
            data: payload, resourceFork: resource
        )
        let tape = ByteTape(envelope)

        var received = Data()
        let result = try await FlattenedFileStream.decode(
            readExactly: { try tape.readExactly($0) },
            encoding: .macOSRoman,
            onData: { received.append($0) }
        )

        #expect(received == payload)
        #expect(result.resourceFork == resource)
        #expect(tape.consumed == envelope.count)
    }

    @Test("the data fork arrives in windows so callers can stream to disk")
    func dataForkIsWindowed() async throws {
        let payload = Data(repeating: 0xAB, count: 10)
        let envelope = classicEnvelope(name: "a.bin", type: "BINA", creator: "????", data: payload)
        let tape = ByteTape(envelope)

        var windows: [Int] = []
        _ = try await FlattenedFileStream.decode(
            readExactly: { try tape.readExactly($0) },
            encoding: .macOSRoman,
            window: 4,
            onData: { windows.append($0.count) }
        )

        #expect(windows == [4, 4, 2])
    }

    @Test("a stream that doesn't open with FILP is rejected")
    func rejectsBareBytes() async {
        let tape = ByteTape(Data(repeating: 0x00, count: 64))
        await #expect(throws: UploadFraming.DecodeError.missingMagic("FILP")) {
            _ = try await FlattenedFileStream.decode(
                readExactly: { try tape.readExactly($0) },
                encoding: .macOSRoman,
                onData: { _ in }
            )
        }
    }
}
