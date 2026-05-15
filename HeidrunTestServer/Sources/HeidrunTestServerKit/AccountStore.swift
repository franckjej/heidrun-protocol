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

public actor AccountStore {
    private var byLogin: [String: ServerAccount]
    private let snapshotURL: URL?

    /// `snapshotURL == nil` keeps the store in-memory (used by tests).
    /// `seeds` are inserted only when the store starts empty.
    public init(snapshotURL: URL?, seeds: [ServerAccount] = []) async {
        self.snapshotURL = snapshotURL
        if let snapshotURL, let loaded = Self.loadSnapshot(at: snapshotURL) {
            self.byLogin = loaded
            return
        }
        var initial: [String: ServerAccount] = [:]
        for seed in seeds {
            initial[seed.login] = seed
        }
        self.byLogin = initial
        if snapshotURL != nil {
            try? Self.writeSnapshot(initial, to: snapshotURL!)
        }
    }

    public func get(_ login: String) -> ServerAccount? {
        byLogin[login]
    }

    public func all() -> [ServerAccount] {
        byLogin.values.sorted { $0.login < $1.login }
    }

    public func create(_ account: ServerAccount) throws {
        guard byLogin[account.login] == nil else {
            throw AccountStoreError.duplicate(login: account.login)
        }
        byLogin[account.login] = account
        try persist()
    }

    public func modify(
        login: String,
        password: String?,
        nickname: String,
        privileges: UserPrivileges
    ) throws {
        guard var existing = byLogin[login] else {
            throw AccountStoreError.missing(login: login)
        }
        existing.nickname = nickname
        existing.privilegesRaw = privileges.rawValue
        if let password {
            existing.password = password
        }
        byLogin[login] = existing
        try persist()
    }

    public func delete(_ login: String) throws {
        guard byLogin.removeValue(forKey: login) != nil else {
            throw AccountStoreError.missing(login: login)
        }
        try persist()
    }

    // MARK: - Snapshot

    private func persist() throws {
        guard let snapshotURL else { return }
        try Self.writeSnapshot(byLogin, to: snapshotURL)
    }

    private static func loadSnapshot(at url: URL) -> [String: ServerAccount]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let array = try? JSONDecoder().decode([ServerAccount].self, from: data) else { return nil }
        var map: [String: ServerAccount] = [:]
        for account in array {
            map[account.login] = account
        }
        return map
    }

    private static func writeSnapshot(_ map: [String: ServerAccount], to url: URL) throws {
        let sorted = map.values.sorted { $0.login < $1.login }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
