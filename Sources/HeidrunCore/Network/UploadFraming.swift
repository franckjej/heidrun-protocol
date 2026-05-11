import Foundation

/// Builds the byte stream for one Hotline file upload (single file, data
/// fork only, no resource fork).
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
///   [12..15]  UInt32 resourceLength (0 for the data-fork-only path)
/// ```
public enum UploadFraming {

    /// Total bytes the side channel will carry after the 16-byte HTXF
    /// handshake (which is sent separately).
    public static func totalSize(nameLength: Int, dataLength: UInt32) -> UInt32 {
        let info = UInt32(74 + nameLength)
        return 40 + info + 16 + dataLength + 16   // + resourceLength (0)
    }

    /// Build the FILP + INFO + DATA-header + DATA + MACR-header bytes.
    /// Resource fork is always empty in this path.
    public static func encode(
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        data: Data,
        encoding: String.Encoding = .macOSRoman
    ) -> Data {
        var out = encodePrefix(
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            dataLength: UInt32(data.count),
            encoding: encoding
        )
        out.append(data)
        out.append(encodeSuffix())
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
        dataLength: UInt32,
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
        out.append(contentsOf: [0x44, 0x41, 0x54, 0x41])      // "DATA"
        out.append(Data(repeating: 0, count: 8))              // reserved
        out.appendBigEndian(dataLength)

        return out
    }

    /// The MACR trailer (16 bytes: "MACR" magic, 8 reserved zeros, 4-byte
    /// resource-fork length of 0). Send this after the data fork bytes
    /// to complete the upload.
    public static func encodeSuffix() -> Data {
        var out = Data()
        out.append(contentsOf: [0x4D, 0x41, 0x43, 0x52])      // "MACR"
        out.append(Data(repeating: 0, count: 8))              // reserved
        out.appendBigEndian(UInt32(0))                        // resource length
        return out
    }

}
