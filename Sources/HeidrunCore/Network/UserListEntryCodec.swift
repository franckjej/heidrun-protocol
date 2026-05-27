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

        // Heidrun extension: an optional `UInt16 emojiByteLen + UTF-8 bytes`
        // block may follow the nick. Legacy entries stop here, so guard on
        // remaining bytes. Always UTF-8, never `encoding`.
        var emoji: String?
        if cursor.remaining >= 2 {
            let emojiLength: UInt16 = cursor.readBigEndian()
            if emojiLength > 0, cursor.remaining >= Int(emojiLength) {
                let emojiBytes = cursor.readData(count: Int(emojiLength))
                emoji = String(data: emojiBytes, encoding: .utf8)
            }
        }

        return User(
            socket: socket,
            icon: icon,
            status: UserStatus(rawValue: status),
            privileges: [],
            nickname: nickname,
            emoji: emoji
        )
    }

    /// Encode a `User` as the body bytes for a `userListEntry` object (key 300).
    public static func encode(
        _ user: User,
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        var data = Data(capacity: 8 + user.nickname.utf8.count)
        data.appendBigEndian(user.socket)
        data.appendBigEndian(user.icon)
        data.appendBigEndian(user.status.rawValue)
        let nameBytes = user.nickname.data(using: encoding, allowLossyConversion: true) ?? Data()
        data.appendBigEndian(UInt16(clamping: nameBytes.count))
        data.append(nameBytes)

        // Heidrun extension: append the emoji as `UInt16 len + UTF-8` only
        // when present. Absent block == legacy layout == no emoji.
        if let emoji = user.emoji, !emoji.isEmpty {
            let emojiBytes = Data(emoji.utf8)
            data.appendBigEndian(UInt16(clamping: emojiBytes.count))
            data.append(emojiBytes)
        }

        return PacketField(key: HotlineObjectKey.userListEntry, data: data)
    }
}
