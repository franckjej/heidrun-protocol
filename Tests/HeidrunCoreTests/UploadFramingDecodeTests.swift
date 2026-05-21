import Foundation
import Testing
@testable import HeidrunCore

@Suite("UploadFraming.decode")
struct UploadFramingDecodeTests {
    @Test("round-trips an upload through encode and decode")
    func roundTripsUpload() throws {
        let original = Data("Hello, Hotline.".utf8)
        let payload = UploadFraming.encode(
            fileName: "greeting.txt",
            type: "TEXT",
            creator: "ttxt",
            creationDate: Date(),
            modificationDate: Date(),
            data: original,
            encoding: .macOSRoman
        )

        let envelope = try UploadFraming.decode(payload, encoding: .macOSRoman)
        #expect(envelope.fileName == "greeting.txt")
        #expect(envelope.data == original)
        #expect(envelope.type == FourCharCode(string: "TEXT"))
        #expect(envelope.creator == FourCharCode(string: "ttxt"))
        #expect(envelope.resourceFork.isEmpty)
    }

    @Test("throws DecodeError.truncated on short payload")
    func rejectsTruncated() {
        let truncated = Data([0x46, 0x49, 0x4C, 0x50])     // just "FILP", nothing after
        do {
            _ = try UploadFraming.decode(truncated)
            #expect(Bool(false), "expected throw")
        } catch UploadFraming.DecodeError.truncated {
            // expected
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("throws DecodeError.missingMagic when the FILP magic is wrong")
    func rejectsMissingMagic() {
        let bogus = Data(repeating: 0, count: 64)
        do {
            _ = try UploadFraming.decode(bogus)
            #expect(Bool(false), "expected throw")
        } catch UploadFraming.DecodeError.missingMagic(let expected) {
            #expect(expected == "FILP")
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("throws DecodeError.missingMagic when the DATA magic is wrong")
    func rejectsWrongDataMagic() throws {
        // Build a valid FILP/INFO header but feed garbage where DATA should be.
        // Easiest: encode a normal payload, then overwrite the DATA magic.
        var payload = UploadFraming.encode(
            fileName: "x",
            type: "TEXT",
            creator: "ttxt",
            creationDate: Date(),
            modificationDate: Date(),
            data: Data([0x01]),
            encoding: .macOSRoman
        )
        // Locate "DATA" magic and corrupt one byte. The magic appears once
        // and is a 4-byte ASCII run, so a substring search is safe.
        let dataMagic = Data("DATA".utf8)
        if let range = payload.range(of: dataMagic) {
            payload[range.lowerBound] = 0xFF
        } else {
            #expect(Bool(false), "couldn't find DATA magic to corrupt")
            return
        }

        do {
            _ = try UploadFraming.decode(payload)
            #expect(Bool(false), "expected throw")
        } catch UploadFraming.DecodeError.missingMagic(let expected) {
            #expect(expected == "DATA")
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }

    @Test("throws DecodeError.missingMagic when the MACR magic is wrong")
    func rejectsWrongMacrMagic() throws {
        var payload = UploadFraming.encode(
            fileName: "x",
            type: "TEXT",
            creator: "ttxt",
            creationDate: Date(),
            modificationDate: Date(),
            data: Data([0x01]),
            encoding: .macOSRoman
        )
        let macrMagic = Data("MACR".utf8)
        if let range = payload.range(of: macrMagic) {
            payload[range.lowerBound] = 0xFF
        } else {
            #expect(Bool(false), "couldn't find MACR magic to corrupt")
            return
        }

        do {
            _ = try UploadFraming.decode(payload)
            #expect(Bool(false), "expected throw")
        } catch UploadFraming.DecodeError.missingMagic(let expected) {
            #expect(expected == "MACR")
        } catch {
            #expect(Bool(false), "wrong error: \(error)")
        }
    }
}
