import Foundation

/// 20-byte Hotline transaction header, big-endian on the wire.
///
/// Replaces `hotHdr` from `HeiHLTypes.h`. The struct is plain data — encoding
/// and decoding round-trip through `Data` so callers can move packets across
/// `NWConnection` or any other byte stream without further ceremony.
public struct PacketHeader: Sendable, Hashable {
    /// Transaction class. `0` for client-originated requests, `1` for replies
    /// in the original protocol.
    public var classID: UInt16

    /// Numeric transaction kind (see `TransactionType` / `InfoTransaction`).
    public var transactionID: UInt16

    /// Per-connection, client-assigned task number used to correlate replies.
    public var taskNumber: UInt32

    /// Server error code. Non-zero on reply means the request failed.
    public var errorID: UInt32

    /// Length of the data portion that follows this header, byte-counted.
    public var dataLength: UInt32

    /// Total length including the header itself; the original protocol carries
    /// it as a duplicate of `dataLength` for sanity-checking by older clients.
    public var totalLength: UInt32

    public init(
        classID: UInt16,
        transactionID: UInt16,
        taskNumber: UInt32,
        errorID: UInt32 = 0,
        dataLength: UInt32 = 0,
        totalLength: UInt32 = 0
    ) {
        self.classID = classID
        self.transactionID = transactionID
        self.taskNumber = taskNumber
        self.errorID = errorID
        self.dataLength = dataLength
        self.totalLength = totalLength
    }

    /// Serialized size of a header on the wire.
    public static let byteCount = 20

    /// Encode the header in big-endian wire format.
    public func encoded() -> Data {
        var out = Data(capacity: Self.byteCount)
        out.appendBigEndian(classID)
        out.appendBigEndian(transactionID)
        out.appendBigEndian(taskNumber)
        out.appendBigEndian(errorID)
        out.appendBigEndian(dataLength)
        out.appendBigEndian(totalLength)
        return out
    }

    /// Decode a header from the start of `data`.
    /// - Returns: `nil` if `data` is shorter than `byteCount`.
    public init?(decoding data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        var cursor = ByteCursor(data: data)
        self.classID       = cursor.readBigEndian()
        self.transactionID = cursor.readBigEndian()
        self.taskNumber    = cursor.readBigEndian()
        self.errorID       = cursor.readBigEndian()
        self.dataLength    = cursor.readBigEndian()
        self.totalLength   = cursor.readBigEndian()
    }
}
