import Foundation

/// Where a resumed transfer should pick up in the file's two forks.
public struct ResumeInfo: Sendable, Hashable {
    public let dataForkOffset: UInt32
    public let resourceForkOffset: UInt32

    public init(dataForkOffset: UInt32 = 0, resourceForkOffset: UInt32 = 0) {
        self.dataForkOffset = dataForkOffset
        self.resourceForkOffset = resourceForkOffset
    }

    /// Convenience for the common "no resume" case.
    public var isFresh: Bool { dataForkOffset == 0 && resourceForkOffset == 0 }
}

/// Codec for the 74-byte resume blob the protocol sends in both
/// directions: clients attach it to download requests (as field 203,
/// `fileResumeInfo`) to ask the server to skip ahead, and servers
/// embed it inside the folder-upload per-item ACK when they have
/// partial data on disk and want the client to skip the prefix.
///
/// Wire layout (HEClient.m line 1652+):
///
/// ```text
/// [0..3]   "RFLT"
/// [4..5]   UInt16 = 1
/// [6..39]  34 bytes reserved
/// [40..41] UInt16 = 2
/// [42..45] "DATA"
/// [46..49] UInt32 dataForkOffset
/// [50..57] 8 bytes reserved
/// [58..61] "MACR"
/// [62..65] UInt32 resourceForkOffset
/// [66..73] 8 bytes reserved
/// ```
public enum ResumeInfoCodec {
    public static let byteCount = 74

    public static func encode(_ info: ResumeInfo) -> Data {
        var out = Data(capacity: byteCount)
        out.append(contentsOf: [0x52, 0x46, 0x4C, 0x54])      // "RFLT"
        out.appendBigEndian(UInt16(1))
        out.append(Data(repeating: 0, count: 34))
        out.appendBigEndian(UInt16(2))
        out.append(contentsOf: [0x44, 0x41, 0x54, 0x41])      // "DATA"
        out.appendBigEndian(info.dataForkOffset)
        out.append(Data(repeating: 0, count: 8))
        out.append(contentsOf: [0x4D, 0x41, 0x43, 0x52])      // "MACR"
        out.appendBigEndian(info.resourceForkOffset)
        out.append(Data(repeating: 0, count: 8))
        return out
    }

    public static func decode(_ data: Data) -> ResumeInfo? {
        guard data.count >= byteCount else { return nil }
        var dataCursor = ByteCursor(data: data, offset: 46)
        let dataOffset: UInt32 = dataCursor.readBigEndian()
        var resCursor = ByteCursor(data: data, offset: 62)
        let resOffset: UInt32 = resCursor.readBigEndian()
        return ResumeInfo(dataForkOffset: dataOffset, resourceForkOffset: resOffset)
    }
}
