import Foundation

/// Wire encoding for `RemotePath` payloads.
///
/// File-system and news transactions both wrap a path as one of:
///   `filePath` (202) for files, `destinationPath` (212) for move/alias
///   destinations, `newsPath` (325) for threaded news.
///
/// On the wire each carries the same payload shape:
///
/// ```
/// u_int16_t  componentCount
/// per component:
///   u_int16_t  reserved (always 0)
///   u_int8_t   nameLength
///   u_int8_t   name[nameLength]
/// ```
extension RemotePath {
    /// Encode the path as the inner bytes of a `filePath` / `newsPath` /
    /// `destinationPath` object (no `hotObj` preamble).
    public func encoded(using encoding: String.Encoding = .macOSRoman) -> Data {
        var data = Data()
        data.appendBigEndian(UInt16(components.count))
        for component in components {
            let bytes = component.data(using: encoding, allowLossyConversion: true) ?? Data()
            let length = UInt8(min(bytes.count, 255))
            data.appendBigEndian(UInt16(0))
            data.append(length)
            data.append(bytes.prefix(Int(length)))
        }
        return data
    }
}

extension PacketField {
    public static func path(
        _ key: HotlineObjectKey,
        _ path: RemotePath,
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        PacketField(key: key, data: path.encoded(using: encoding))
    }
}
