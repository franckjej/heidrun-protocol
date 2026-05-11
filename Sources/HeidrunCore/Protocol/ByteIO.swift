import Foundation

/// A read cursor over a `Data` buffer that handles big-endian numeric reads.
///
/// Hotline transactions are big-endian on the wire. `ByteCursor` keeps the
/// reader and the offset in one place so a decoder can read fields in
/// declaration order without juggling indices.
public struct ByteCursor: Sendable {
    public let data: Data
    public private(set) var offset: Int

    public init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    /// Bytes still available between `offset` and the end of `data`.
    public var remaining: Int { data.count - offset }

    /// `true` when the cursor has consumed every byte.
    public var isAtEnd: Bool { remaining <= 0 }

    /// Read `T` as a big-endian fixed-width integer and advance the cursor.
    /// Stops at the end of the buffer rather than crashing — short reads
    /// return zero, so callers should check `remaining` before reading.
    public mutating func readBigEndian<T: FixedWidthInteger>() -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return 0 }
        var value: T = 0
        for _ in 0..<size {
            value = (value << 8) | T(data[data.startIndex + offset])
            offset += 1
        }
        return value
    }

    /// Read `count` bytes as raw `Data` and advance the cursor.
    public mutating func readData(count: Int) -> Data {
        let take = min(count, remaining)
        let start = data.startIndex + offset
        let slice = data.subdata(in: start..<(start + take))
        offset += take
        return slice
    }
}

extension Data {
    /// Append a fixed-width integer in big-endian order.
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        let size = MemoryLayout<T>.size
        for i in stride(from: size - 1, through: 0, by: -1) {
            append(UInt8(truncatingIfNeeded: value >> (i * 8)))
        }
    }
}
