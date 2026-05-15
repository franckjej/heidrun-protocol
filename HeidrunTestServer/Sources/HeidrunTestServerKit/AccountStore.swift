import Foundation
import HeidrunCore

/// One stored server-side account. The test server keeps the password
/// in plaintext on purpose — this is a fixture, not a real server.
public struct ServerAccount: Codable, Sendable, Hashable {
    public var login: String
    public var password: String
    public var nickname: String
    /// `UserPrivileges.rawValue`. Stored as a raw `UInt64` so the JSON
    /// snapshot remains stable even if `UserPrivileges` grows new bits.
    public var privilegesRaw: UInt64

    public init(
        login: String,
        password: String,
        nickname: String,
        privileges: UserPrivileges
    ) {
        self.login = login
        self.password = password
        self.nickname = nickname
        self.privilegesRaw = privileges.rawValue
    }

    public var privileges: UserPrivileges {
        UserPrivileges(rawValue: privilegesRaw)
    }
}

public enum AccountStoreError: Error, Sendable, Equatable {
    case duplicate(login: String)
    case missing(login: String)
    case persistenceFailed(message: String)
}
