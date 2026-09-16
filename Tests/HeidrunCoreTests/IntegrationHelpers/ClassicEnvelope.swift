import Foundation
@testable import HeidrunCore

/// Hand-built two-fork flattened file object (INFO + DATA, no MACR) —
/// byte-for-byte the shape a classic Hotline server ships on a
/// single-file download. `dataForkLength` lets a resumed envelope
/// announce the remainder while `data` carries only the tail bytes.
func classicEnvelope(
    name: String,
    type: String = "BINA",
    creator: String = "????",
    data: Data
) -> Data {
    let nameBytes = Data(name.utf8)
    var out = Data()
    out.append(contentsOf: Array("FILP".utf8))
    out.appendBigEndian(UInt16(1))                 // version
    out.append(Data(repeating: 0, count: 16))      // reserved
    out.appendBigEndian(UInt16(2))                 // forkCount
    out.append(contentsOf: Array("INFO".utf8))
    out.append(Data(repeating: 0, count: 8))
    out.appendBigEndian(UInt32(74 + nameBytes.count))
    out.append(contentsOf: Array("AMAC".utf8))
    out.append(contentsOf: Array(type.utf8))
    out.append(contentsOf: Array(creator.utf8))
    out.append(Data(repeating: 0, count: 4))
    out.appendBigEndian(UInt32(256))
    out.append(Data(repeating: 0, count: 32))
    out.appendBigEndian(UInt16(1904))
    out.append(Data(repeating: 0, count: 2))
    out.appendBigEndian(UInt32(0xE5E7_3575))
    out.appendBigEndian(UInt16(1904))
    out.append(Data(repeating: 0, count: 2))
    out.appendBigEndian(UInt32(0xE5E7_3575))
    out.append(Data(repeating: 0, count: 2))
    out.appendBigEndian(UInt16(nameBytes.count))
    out.append(nameBytes)
    out.append(Data(repeating: 0, count: 2))       // comment length 0
    out.append(contentsOf: Array("DATA".utf8))
    out.append(Data(repeating: 0, count: 8))
    out.appendBigEndian(UInt32(data.count))
    out.append(data)
    return out
}
