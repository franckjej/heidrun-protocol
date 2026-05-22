import Foundation

/// Wire format for the 16-byte `hotXFerHdr` the client sends as the very
/// first thing on a transfer-port connection.
///
/// ```
/// u_int8_t  magic[4]      // "HTXF"
/// u_int32_t transferID    // matches the id from the control-channel reply
/// u_int32_t transferSize  // 0 for downloads (server already knows it),
///                         // total bytes for uploads
/// u_int32_t reserved      // 0
/// ```
public enum TransferHandshake {
    public static let magic: [UInt8] = [0x48, 0x54, 0x58, 0x46] // "HTXF"

    public static let byteCount = 16

    public static func encode(transferID: UInt32, transferSize: UInt32 = 0) -> Data {
        var data = Data(capacity: byteCount)
        data.append(contentsOf: magic)
        data.appendBigEndian(transferID)
        data.appendBigEndian(transferSize)
        data.appendBigEndian(UInt32(0))
        return data
    }

    /// 16-byte handshake the original Heidrun sends on a folder upload's
    /// side channel (HETransferThread.m line 763). The trailing
    /// `_reserved1` UInt32 slot is split into two UInt16 fields with
    /// values `1, 0` — the marker the server uses to detect that the
    /// transfer is a folder rather than a single file.
    public static func encodeFolderUpload(transferID: UInt32) -> Data {
        var data = Data(capacity: byteCount)
        data.append(contentsOf: magic)
        data.appendBigEndian(transferID)
        data.appendBigEndian(UInt32(0))
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(0))
        return data
    }

    /// 18-byte handshake for a folder download (HETransferThread.m
    /// line 195). Adds a third trailing UInt16 = 3 on top of the
    /// folder-upload handshake.
    public static let folderDownloadByteCount = 18

    public static func encodeFolderDownload(transferID: UInt32) -> Data {
        var data = Data(capacity: folderDownloadByteCount)
        data.append(contentsOf: magic)
        data.appendBigEndian(transferID)
        data.appendBigEndian(UInt32(0))
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt16(0))
        data.appendBigEndian(UInt16(3))
        return data
    }

    /// 16-byte handshake for a server-banner download (transID 212).
    /// Per the Hotline protocol spec, the trailing `_reserved1` UInt32
    /// is split into two UInt16 fields with values `2, 0` — the
    /// marker the server uses to distinguish a banner stream from a
    /// regular file download (which uses 0, 0).
    public static func encodeBanner(transferID: UInt32) -> Data {
        var data = Data(capacity: byteCount)
        data.append(contentsOf: magic)
        data.appendBigEndian(transferID)
        data.appendBigEndian(UInt32(0))
        data.appendBigEndian(UInt16(2))
        data.appendBigEndian(UInt16(0))
        return data
    }
}
