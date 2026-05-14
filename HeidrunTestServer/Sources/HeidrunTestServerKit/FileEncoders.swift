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
        var data = Data(capacity: 20 + file.name.count)
        append4cc(&data, file.type)
        append4cc(&data, file.creator)
        data.appendBE(file.size)
        data.appendBE(file.itemCount)
        let nameBytes = file.name.data(using: encoding, allowLossyConversion: true) ?? Data()
        data.appendBE(UInt32(clamping: nameBytes.count))
        data.append(nameBytes)
        return PacketField(key: HotlineObjectKey.fileListEntry, data: data)
    }

    /// Encode a 4-character `longFileType` / `longFileCreator` payload.
    /// Wire layout: just the four raw bytes.
    static func longFourCC(_ value: HeidrunCore.FourCharCode) -> Data {
        var data = Data()
        append4cc(&data, value)
        return data
    }

    /// Encode a Hotline date field (8 bytes: UInt16 baseYear + 2 reserved +
    /// UInt32 secondsSince1904).
    static func dateField(_ date: Date, key: HotlineObjectKey) -> PacketField {
        var data = Data(capacity: 8)
        data.appendBE(UInt16(1904))                  // base year
        data.appendBE(UInt16(0))                     // 2 reserved bytes
        data.appendBE(HotlineDate.encode(date))
        return PacketField(key: key, data: data)
    }

    private static func append4cc(_ out: inout Data, _ code: HeidrunCore.FourCharCode) {
        let raw = code.rawValue
        out.append(UInt8((raw >> 24) & 0xFF))
        out.append(UInt8((raw >> 16) & 0xFF))
        out.append(UInt8((raw >>  8) & 0xFF))
        out.append(UInt8( raw        & 0xFF))
    }
}

/// Decode the inbound FILP / INFO / DATA / MACR envelope the client
/// sends on an upload's side channel. The total byte count is announced
/// in the HTXF preamble's transferSize field.
///
/// Returns the data-fork bytes and (best-effort) the embedded file name.
/// Most fields are ignored — the integration tests just want the body.
struct UploadParseResult {
    var fileName: String
    var data: Data
    var type: HeidrunCore.FourCharCode
    var creator: HeidrunCore.FourCharCode
}

enum UploadFramingParser {
    enum ParseError: Error {
        case truncated
        case missingMagic(String)
    }

    static func parse(_ payload: Data, encoding: String.Encoding = .macOSRoman) throws -> UploadParseResult {
        var cursor = 0
        func need(_ count: Int) throws {
            guard cursor + count <= payload.count else { throw ParseError.truncated }
        }
        func readMagic(_ expected: String) throws {
            try need(4)
            let chunk = payload[cursor..<cursor + 4]
            let ascii = String(data: chunk, encoding: .ascii) ?? ""
            cursor += 4
            guard ascii == expected else { throw ParseError.missingMagic(expected) }
        }
        func readBEUInt16() throws -> UInt16 {
            try need(2)
            let v = UInt16(payload[cursor]) << 8 | UInt16(payload[cursor + 1])
            cursor += 2
            return v
        }
        func readBEUInt32() throws -> UInt32 {
            try need(4)
            let v: UInt32 = UInt32(payload[cursor]) << 24
                          | UInt32(payload[cursor + 1]) << 16
                          | UInt32(payload[cursor + 2]) << 8
                          | UInt32(payload[cursor + 3])
            cursor += 4
            return v
        }
        func skip(_ n: Int) throws {
            try need(n)
            cursor += n
        }
        func readBytes(_ n: Int) throws -> Data {
            try need(n)
            let bytes = payload[cursor..<cursor + n]
            cursor += n
            return Data(bytes)
        }

        // FILP header (40 bytes).
        try readMagic("FILP")
        try skip(2)   // version
        try skip(14)  // reserved
        _ = try readBEUInt32()   // forkCount (typically 3)
        try readMagic("INFO")
        try skip(8)              // reserved
        let infoLength = try readBEUInt32()

        // INFO block contents.
        let infoStart = cursor
        try skip(4)              // "AMAC"
        let typeCode = try readBEUInt32()
        let creatorCode = try readBEUInt32()
        try skip(4)              // reserved
        _ = try readBEUInt32()   // magic constant (256)
        try skip(32)             // reserved
        try skip(2)              // 1904 base year
        try skip(2)              // reserved
        _ = try readBEUInt32()   // creation seconds
        try skip(2)              // base year
        try skip(2)              // reserved
        _ = try readBEUInt32()   // modification seconds
        try skip(2)              // reserved
        let nameLen = try readBEUInt16()
        let nameBytes = try readBytes(Int(nameLen))
        let fileName = String(data: nameBytes, encoding: encoding) ?? ""

        // Skip the trailing pad inside the INFO block.
        let infoConsumed = cursor - infoStart
        if infoConsumed < Int(infoLength) {
            try skip(Int(infoLength) - infoConsumed)
        }

        // DATA fork header + bytes.
        try readMagic("DATA")
        try skip(8)              // reserved
        let dataLength = try readBEUInt32()
        let fork = try readBytes(Int(dataLength))

        // MACR trailer (resource fork). Read and discard — clients always
        // send a zero-length resource fork in this codebase.
        try readMagic("MACR")
        try skip(8)
        let resourceLength = try readBEUInt32()
        if resourceLength > 0 {
            try skip(Int(resourceLength))
        }

        return UploadParseResult(
            fileName: fileName,
            data: fork,
            type: fourCharCode(from: typeCode),
            creator: fourCharCode(from: creatorCode)
        )
    }

    private static func fourCharCode(from raw: UInt32) -> HeidrunCore.FourCharCode {
        HeidrunCore.FourCharCode(rawValue: raw)
    }
}
