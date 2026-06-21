import Foundation

/// Builds the byte stream for one Hotline file upload (single file, with
/// optional resource fork).
///
/// Layout, derived from `HETransferThread.m -startUploadWithPorts:`
/// (lines ~925-970):
///
/// ```text
/// FILP header (40 bytes):
///   [0..3]    "FILP"
///   [4..5]    UInt16 version = 1
///   [6..19]   14 bytes reserved
///   [20..23]  UInt32 forkCount = 3
///   [24..27]  "INFO"
///   [28..35]  8 bytes reserved
///   [36..39]  UInt32 infoBlockLength (= 74 + name length)
///
/// INFO block (74 + nameLen bytes):
///   [0..3]    "AMAC"
///   [4..7]    UInt32 HFS type code
///   [8..11]   UInt32 HFS creator code
///   [12..15]  4 bytes reserved
///   [16..19]  UInt32 = 256
///   [20..51]  32 bytes reserved
///   [52..53]  UInt16 1904 (creation epoch year)
///   [54..55]  2 bytes reserved
///   [56..59]  UInt32 creationDate (seconds since 1904)
///   [60..61]  UInt16 1904 (modification epoch year)
///   [62..63]  2 bytes reserved
///   [64..67]  UInt32 modificationDate
///   [68..69]  2 bytes reserved
///   [70..71]  UInt16 nameLength
///   [72..72+nameLen-1] name bytes
///   [...]     2 bytes reserved (trailing pad)
///
/// DATA fork header (16 bytes):
///   [0..3]    "DATA"
///   [4..11]   8 bytes reserved
///   [12..15]  UInt32 dataLength
///   data bytes follow
///
/// MACR fork header (16 bytes, same shape):
///   [0..3]    "MACR"
///   [4..11]   8 bytes reserved
///   [12..15]  UInt32 resourceLength
///   resourceLength bytes of resource fork follow
/// ```
public enum UploadFraming {

    /// Build a 16-byte FFO fork header carrying a length up to 64 bits.
    /// The high 32 bits live at offset 4-7 (the first reserved word) and
    /// the low 32 bits at offset 12-15. For legacy small files the high
    /// word is zero, so the bytes are identical to the historical
    /// 32-bit-only header.
    /// ```
    /// [0..3]   magic
    /// [4..7]   UInt32 high32(length)
    /// [8..11]  4 zero/reserved bytes
    /// [12..15] UInt32 low32(length)
    /// ```
    static func forkHeader(magic: String, length: UInt64) -> Data {
        var out = Data(capacity: 16)
        out.append(magic.data(using: .ascii) ?? Data(repeating: 0, count: 4))
        out.appendBigEndian(UInt32(truncatingIfNeeded: length >> 32))
        out.append(Data(repeating: 0, count: 4))
        out.appendBigEndian(UInt32(truncatingIfNeeded: length))
        return out
    }

    /// Recover the 64-bit fork length from a 16-byte FFO fork header.
    static func forkLength(from header: Data) -> UInt64 {
        var cursor = ByteCursor(data: header)
        _ = cursor.readData(count: 4)              // magic
        let high: UInt32 = cursor.readBigEndian()  // offset 4-7
        _ = cursor.readData(count: 4)              // reserved 8-11
        let low: UInt32 = cursor.readBigEndian()   // offset 12-15
        return (UInt64(high) << 32) | UInt64(low)
    }

    /// Total bytes the side channel will carry after the 16-byte HTXF
    /// handshake (which is sent separately).
    public static func totalSize(
        nameLength: Int,
        dataLength: UInt32,
        resourceLength: UInt32 = 0
    ) -> UInt32 {
        let info = UInt32(74 + nameLength)
        return 40 + info + 16 + dataLength + 16 + resourceLength
    }

    /// Build the FILP + INFO + DATA-header + DATA + MACR-header + (optional)
    /// resource-fork bytes. Pass an empty `resourceFork` for data-fork-only
    /// uploads.
    public static func encode(
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        data: Data,
        resourceFork: Data = Data(),
        encoding: String.Encoding = .macOSRoman
    ) -> Data {
        var out = encodePrefix(
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            dataLength: UInt64(data.count),
            encoding: encoding
        )
        out.append(data)
        out.append(encodeSuffix(resourceFork: resourceFork))
        return out
    }

    /// Build everything up to and including the DATA fork header (FILP +
    /// INFO + DATA-hdr). Use this when the data fork is too large to hold
    /// in memory and the caller wants to stream it in chunks: send this
    /// prefix, then the fork bytes, then `encodeSuffix()` — total bytes
    /// on the wire equal `totalSize(...)`.
    public static func encodePrefix(
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        dataLength: UInt64,
        encoding: String.Encoding = .macOSRoman
    ) -> Data {
        let nameBytes = fileName.data(using: encoding, allowLossyConversion: true) ?? Data()
        let nameLen = UInt16(min(nameBytes.count, Int(UInt16.max)))
        let infoLength = UInt32(74) + UInt32(nameLen)

        var out = Data()

        // FILP header (40 bytes).
        out.append(contentsOf: [0x46, 0x49, 0x4C, 0x50])     // "FILP"
        out.appendBigEndian(UInt16(1))                        // version
        out.append(Data(repeating: 0, count: 14))             // reserved
        out.appendBigEndian(UInt32(3))                        // fork count
        out.append(contentsOf: [0x49, 0x4E, 0x46, 0x4F])      // "INFO"
        out.append(Data(repeating: 0, count: 8))              // reserved
        out.appendBigEndian(infoLength)

        // INFO block.
        out.append(contentsOf: [0x41, 0x4D, 0x41, 0x43])      // "AMAC"
        out.appendBigEndian(type.rawValue)
        out.appendBigEndian(creator.rawValue)
        out.append(Data(repeating: 0, count: 4))              // reserved
        out.appendBigEndian(UInt32(256))                      // magic constant
        out.append(Data(repeating: 0, count: 32))             // reserved
        out.appendBigEndian(UInt16(1904))                     // cre epoch year
        out.append(Data(repeating: 0, count: 2))              // reserved
        out.appendBigEndian(HotlineDate.encode(creationDate))
        out.appendBigEndian(UInt16(1904))                     // mod epoch year
        out.append(Data(repeating: 0, count: 2))              // reserved
        out.appendBigEndian(HotlineDate.encode(modificationDate))
        out.append(Data(repeating: 0, count: 2))              // reserved
        out.appendBigEndian(nameLen)
        out.append(nameBytes.prefix(Int(nameLen)))
        out.append(Data(repeating: 0, count: 2))              // trailing pad

        // DATA fork header (16 bytes).
        out.append(forkHeader(magic: "DATA", length: dataLength))

        return out
    }

    /// The MACR trailer plus optional resource-fork bytes. The trailer is
    /// 16 bytes (`MACR` magic + 8 reserved zeros + UInt32 length) followed
    /// by `resourceFork.count` bytes of fork content. For a data-fork-only
    /// upload pass an empty `resourceFork` — the trailer alone is 16 bytes
    /// and the length field reads zero, matching the historical wire
    /// behaviour.
    public static func encodeSuffix(resourceFork: Data = Data()) -> Data {
        var out = Data()
        out.append(forkHeader(magic: "MACR", length: UInt64(resourceFork.count)))
        out.append(resourceFork)
        return out
    }

    public enum DecodeError: Error, Equatable {
        case truncated
        case missingMagic(String)
    }

    /// Decode the inbound FILP / INFO / DATA / MACR envelope a client
    /// sends on an upload's HTXF side-channel. The byte count is
    /// announced by the HTXF preamble's `transferSize` field, so the
    /// caller is expected to hand over an exact-length buffer.
    public static func decode(
        _ payload: Data,
        encoding: String.Encoding = .macOSRoman
    ) throws -> UploadEnvelope {
        var cursor = 0
        func need(_ count: Int) throws {
            guard cursor + count <= payload.count else { throw DecodeError.truncated }
        }
        func readMagic(_ expected: String) throws {
            try need(4)
            let chunk = payload[(payload.startIndex + cursor)..<(payload.startIndex + cursor + 4)]
            let ascii = String(data: chunk, encoding: .ascii) ?? ""
            cursor += 4
            guard ascii == expected else { throw DecodeError.missingMagic(expected) }
        }
        func readBEUInt16() throws -> UInt16 {
            try need(2)
            let base = payload.startIndex + cursor
            let value = UInt16(payload[base]) << 8 | UInt16(payload[base + 1])
            cursor += 2
            return value
        }
        func readBEUInt32() throws -> UInt32 {
            try need(4)
            let base = payload.startIndex + cursor
            let value: UInt32 = UInt32(payload[base]) << 24
                              | UInt32(payload[base + 1]) << 16
                              | UInt32(payload[base + 2]) << 8
                              | UInt32(payload[base + 3])
            cursor += 4
            return value
        }
        func skip(_ count: Int) throws {
            try need(count)
            cursor += count
        }
        func readBytes(_ count: Int) throws -> Data {
            try need(count)
            let base = payload.startIndex + cursor
            let bytes = payload[base..<(base + count)]
            cursor += count
            return Data(bytes)
        }

        try readMagic("FILP")
        try skip(2)                                   // version
        try skip(14)                                  // reserved
        _ = try readBEUInt32()                        // forkCount, typically 3
        try readMagic("INFO")
        try skip(8)                                   // reserved
        let infoLength = try readBEUInt32()

        let infoStart = cursor
        try skip(4)                                   // "AMAC"
        let typeCode = try readBEUInt32()
        let creatorCode = try readBEUInt32()
        try skip(4)                                   // reserved
        _ = try readBEUInt32()                        // magic constant 256
        try skip(32)                                  // reserved
        try skip(2)                                   // 1904 base year
        try skip(2)                                   // reserved
        _ = try readBEUInt32()                        // creation seconds
        try skip(2)                                   // base year
        try skip(2)                                   // reserved
        _ = try readBEUInt32()                        // modification seconds
        try skip(2)                                   // reserved
        let nameLength = try readBEUInt16()
        let nameBytes = try readBytes(Int(nameLength))
        let fileName = String(data: nameBytes, encoding: encoding) ?? ""

        let infoConsumed = cursor - infoStart
        if infoConsumed < Int(infoLength) {
            try skip(Int(infoLength) - infoConsumed)
        }

        try need(16)
        let dataHeader = try readBytes(16)
        guard String(data: dataHeader.prefix(4), encoding: .ascii) == "DATA" else {
            throw DecodeError.missingMagic("DATA")
        }
        let dataLength = UploadFraming.forkLength(from: dataHeader)
        guard dataLength <= UInt64(Int.max) else { throw DecodeError.truncated }
        let fork = try readBytes(Int(dataLength))

        try need(16)
        let resourceHeader = try readBytes(16)
        guard String(data: resourceHeader.prefix(4), encoding: .ascii) == "MACR" else {
            throw DecodeError.missingMagic("MACR")
        }
        let resourceLength = UploadFraming.forkLength(from: resourceHeader)
        guard resourceLength <= UInt64(Int.max) else { throw DecodeError.truncated }
        let resourceFork = resourceLength > 0 ? try readBytes(Int(resourceLength)) : Data()

        return UploadEnvelope(
            fileName: fileName,
            data: fork,
            resourceFork: resourceFork,
            type: FourCharCode(rawValue: typeCode),
            creator: FourCharCode(rawValue: creatorCode)
        )
    }
}
