import Foundation

/// Decodes the variable-length `userListEntry` blob (object key 300).
///
/// Wire layout (big-endian throughout):
///
/// ```
/// u_int16_t socket
/// u_int16_t icon
/// u_int16_t status     // colour byte + flags byte
/// u_int16_t nickLength
/// u_int8_t  nick[nickLength]
/// ```
///
/// Mirrors the `hotUserList` struct from the original `HeiHLTypes.h`
/// plus the trailing nickname.
public enum UserListEntryCodec {
    public static func decode(
        _ data: Data,
        encoding: String.Encoding = .macOSRoman
    ) -> User? {
        guard data.count >= 8 else { return nil }
        var cursor = ByteCursor(data: data)
        let socket: UInt16     = cursor.readBigEndian()
        let icon: UInt16     = cursor.readBigEndian()
        let status: UInt16     = cursor.readBigEndian()
        let length: UInt16     = cursor.readBigEndian()
        guard cursor.remaining >= Int(length) else { return nil }
        let nickBytes = cursor.readData(count: Int(length))
        let nickname = String(data: nickBytes, encoding: encoding) ?? ""
        return User(
            socket: socket,
            icon: icon,
            status: UserStatus(rawValue: status),
            privileges: [],
            nickname: nickname
        )
    }
}
