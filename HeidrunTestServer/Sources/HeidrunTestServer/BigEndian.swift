import Foundation

/// Tiny big-endian helpers. HeidrunCore has equivalents but they're
/// internal — this file keeps the test server self-contained.
extension Data {
    mutating func appendBE(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
