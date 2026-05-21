import Foundation
import HeidrunCore

/// Encoders + decoders for the file-related side of the protocol that
/// live only on the server side (production code has the complementary
/// halves in `FileListEntryCodec` and `UploadFraming`).
enum FileEncoders {

    /// Encode one `fileListEntry` object (key 200).
    ///
    /// Wire layout matches `FileListEntryCodec.decode`:
    /// ```
    /// u_int8_t  type[4]
    /// u_int8_t  creator[4]
    /// u_int32_t size
    /// u_int32_t nrItems
    /// u_int32_t nameLength
    /// u_int8_t  name[nameLength]
    /// ```
    static func fileListEntry(_ file: RemoteFile, encoding: String.Encoding = .macOSRoman) -> PacketField {
        FileListEntryCodec.encode(file, encoding: encoding)
    }

    /// Encode a 4-character `longFileType` / `longFileCreator` payload.
    /// Wire layout: just the four raw bytes.
    static func longFourCC(_ value: HeidrunCore.FourCharCode) -> Data {
        LongFourCC.encode(value)
    }

    /// Encode a Hotline date field (8 bytes: UInt16 baseYear + 2 reserved +
    /// UInt32 secondsSince1904).
    static func dateField(_ date: Date, key: HotlineObjectKey) -> PacketField {
        HotlineDateField.encode(date, key: key)
    }
}

/// Thin shim over `UploadFraming.decode` — preserves the call-site API
/// used by `TransferListener` without duplicating the wire-parsing logic.
struct UploadParseResult {
    var fileName: String
    var data: Data
    var type: HeidrunCore.FourCharCode
    var creator: HeidrunCore.FourCharCode

    init(envelope: UploadEnvelope) {
        self.fileName = envelope.fileName
        self.data = envelope.data
        self.type = envelope.type
        self.creator = envelope.creator
    }
}

enum UploadFramingParser {
    typealias ParseError = UploadFraming.DecodeError

    static func parse(_ payload: Data, encoding: String.Encoding = .macOSRoman) throws -> UploadParseResult {
        let envelope = try UploadFraming.decode(payload, encoding: encoding)
        return UploadParseResult(envelope: envelope)
    }
}
