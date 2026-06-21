import Foundation

/// One field inside a transaction packet payload.
public struct PacketField: Sendable, Hashable {
    public let key: UInt16
    public let data: Data

    public init(key: UInt16, data: Data) {
        self.key = key
        self.data = data
    }

    public init(key: HotlineObjectKey, data: Data) {
        self.key = key.rawValue
        self.data = data
    }

    /// Convenience for big-endian fixed-width integer fields.
    public static func uint8(_ key: HotlineObjectKey, _ value: UInt8) -> PacketField {
        PacketField(key: key, data: Data([value]))
    }

    public static func uint16(_ key: HotlineObjectKey, _ value: UInt16) -> PacketField {
        var data = Data()
        data.appendBigEndian(value)
        return PacketField(key: key, data: data)
    }

    public static func uint32(_ key: HotlineObjectKey, _ value: UInt32) -> PacketField {
        var data = Data()
        data.appendBigEndian(value)
        return PacketField(key: key, data: data)
    }

    public static func uint64(_ key: HotlineObjectKey, _ value: UInt64) -> PacketField {
        var data = Data()
        data.appendBigEndian(value)
        return PacketField(key: key, data: data)
    }

    /// String field encoded with the supplied encoding (default Mac Roman,
    /// matching the original Heidrun build's preference).
    public static func string(
        _ key: HotlineObjectKey,
        _ value: String,
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        let bytes = value.data(using: encoding, allowLossyConversion: true) ?? Data()
        return PacketField(key: key, data: bytes)
    }

    /// String field with each byte bit-inverted on the wire (the original
    /// Hotline obfuscation for login + password).
    public static func obfuscatedString(
        _ key: HotlineObjectKey,
        _ value: String,
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        var bytes = value.data(using: encoding, allowLossyConversion: true) ?? Data()
        for i in bytes.indices {
            bytes[i] = bytes[i] ^ 0xFF
        }
        return PacketField(key: key, data: bytes)
    }
}

public enum PacketCodec {
    /// Encode a complete transaction packet (header + body).
    public static func encode(
        classID: UInt16,
        transactionID: UInt16,
        taskNumber: UInt32,
        errorID: UInt32 = 0,
        fields: [PacketField]
    ) -> Data {
        // Body: 2-byte object count followed by each object.
        var body = Data()
        body.appendBigEndian(UInt16(fields.count))
        for field in fields {
            body.appendBigEndian(field.key)
            body.appendBigEndian(UInt16(clamping: field.data.count))
            body.append(field.data)
        }

        let header = PacketHeader(
            classID: classID,
            transactionID: transactionID,
            taskNumber: taskNumber,
            errorID: errorID,
            dataLength: UInt32(body.count),
            totalLength: UInt32(body.count)
        )

        var out = Data(capacity: PacketHeader.byteCount + body.count)
        out.append(header.encoded())
        out.append(body)
        return out
    }

    /// Parse a body (everything after the 20-byte header) into typed
    /// fields. Order is preserved so callers that need duplicate keys
    /// (e.g. the user-list reply, which carries N `userListEntry` fields)
    /// can iterate.
    public static func decodeBody(_ body: Data) -> [PacketField] {
        guard body.count >= 2 else { return [] }
        var cursor = ByteCursor(data: body)
        let count: UInt16 = cursor.readBigEndian()
        var fields: [PacketField] = []
        fields.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard cursor.remaining >= 4 else { break }
            let key: UInt16 = cursor.readBigEndian()
            let length: UInt16 = cursor.readBigEndian()
            guard cursor.remaining >= Int(length) else { break }
            let data = cursor.readData(count: Int(length))
            fields.append(PacketField(key: key, data: data))
        }
        return fields
    }
}

extension Sequence where Element == PacketField {
    /// First field with a matching key, if any.
    public func first(_ key: HotlineObjectKey) -> PacketField? {
        first(where: { $0.key == key.rawValue })
    }

    /// Single-byte integer at the given key, or `nil` when absent / empty.
    public func uint8(_ key: HotlineObjectKey) -> UInt8? {
        guard let field = first(key), let firstByte = field.data.first else { return nil }
        return firstByte
    }

    /// Big-endian integer at the given key, or `nil` when absent or the
    /// data is the wrong size.
    public func uint16(_ key: HotlineObjectKey) -> UInt16? {
        guard let field = first(key) else { return nil }
        var cursor = ByteCursor(data: field.data)
        guard cursor.remaining >= 2 else { return nil }
        return cursor.readBigEndian()
    }

    public func uint32(_ key: HotlineObjectKey) -> UInt32? {
        guard let field = first(key) else { return nil }
        var cursor = ByteCursor(data: field.data)
        guard cursor.remaining >= 4 else { return nil }
        return cursor.readBigEndian()
    }

    public func uint64(_ key: HotlineObjectKey) -> UInt64? {
        guard let field = first(key) else { return nil }
        var cursor = ByteCursor(data: field.data)
        guard cursor.remaining >= 8 else { return nil }
        return cursor.readBigEndian()
    }

    public func string(_ key: HotlineObjectKey, encoding: String.Encoding = .macOSRoman) -> String? {
        guard let field = first(key) else { return nil }
        return String(data: field.data, encoding: encoding)
    }

    /// Decode an obfuscated string (login or password) by inverting every
    /// byte before string-decoding.
    public func obfuscatedString(_ key: HotlineObjectKey, encoding: String.Encoding = .macOSRoman) -> String? {
        guard let field = first(key) else { return nil }
        var bytes = field.data
        for i in bytes.indices {
            bytes[i] = bytes[i] ^ 0xFF
        }
        return String(data: bytes, encoding: encoding)
    }

    /// Decode a Hotline 8-byte date field.
    ///
    /// Wire layout (file & news date objects share it):
    /// ```
    /// UInt16 baseYear  + 2 reserved  + UInt32 secondsSinceBaseYear
    /// ```
    public func date(_ key: HotlineObjectKey) -> Date? {
        guard let field = first(key), field.data.count >= 8 else { return nil }
        var cursor = ByteCursor(data: field.data)
        let baseYear: UInt16 = cursor.readBigEndian()
        _ = cursor.readData(count: 2)
        let seconds: UInt32 = cursor.readBigEndian()
        return HotlineDate.decode(baseYear: baseYear, seconds: seconds)
    }
}
