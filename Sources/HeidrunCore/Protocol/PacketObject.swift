import Foundation

/// 4-byte TLV header that introduces every object inside a packet payload.
///
/// Replaces `hotObj` from `HeiHLTypes.h`. The body bytes follow immediately
/// in the packet stream and are accessed through `data` once decoded.
public struct PacketObject: Sendable, Hashable {
    /// Application-defined object identifier.
    public var objectID: UInt16

    /// Length of the body bytes that follow.
    public var dataLength: UInt16

    /// The body itself.
    public var data: Data

    public init(objectID: UInt16, data: Data) {
        self.objectID = objectID
        self.dataLength = UInt16(clamping: data.count)
        self.data = data
    }

    /// Serialized size on the wire (including the 4-byte preamble).
    public var byteCount: Int { 4 + Int(dataLength) }

    /// Encode the object in big-endian wire format.
    public func encoded() -> Data {
        var out = Data(capacity: byteCount)
        out.appendBigEndian(objectID)
        out.appendBigEndian(dataLength)
        out.append(data.prefix(Int(dataLength)))
        return out
    }

    /// Decode an object starting at `cursor` and advance it past the body.
    /// - Returns: `nil` if the buffer is too short to hold the announced length.
    public static func decode(from cursor: inout ByteCursor) -> PacketObject? {
        guard cursor.remaining >= 4 else { return nil }
        let objectID: UInt16 = cursor.readBigEndian()
        let length: UInt16 = cursor.readBigEndian()
        guard cursor.remaining >= Int(length) else { return nil }
        let body = cursor.readData(count: Int(length))
        return PacketObject(objectID: objectID, data: body)
    }
}
