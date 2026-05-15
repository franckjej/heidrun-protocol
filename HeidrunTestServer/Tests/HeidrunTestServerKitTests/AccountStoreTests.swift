import Foundation
import Testing
@testable import HeidrunTestServerKit
import HeidrunCore

@Suite("ServerAccount value type")
struct ServerAccountTests {
    @Test("init stores raw privilege bits")
    func storesRawPrivileges() {
        let account = ServerAccount(
            login: "admin",
            password: "admin",
            nickname: "Administrator",
            privileges: [.uploadFiles, .downloadFiles, .canBroadcast]
        )
        let expected = UserPrivileges([.uploadFiles, .downloadFiles, .canBroadcast]).rawValue
        #expect(account.login == "admin")
        #expect(account.password == "admin")
        #expect(account.nickname == "Administrator")
        #expect(account.privilegesRaw == expected)
    }

    @Test("Codable round-trip preserves every field")
    func codableRoundTrip() throws {
        let original = ServerAccount(
            login: "carol",
            password: "s3cret",
            nickname: "Carol",
            privileges: [.sendChat, .readNews]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerAccount.self, from: encoded)
        #expect(decoded == original)
        #expect(decoded.privilegesRaw == original.privilegesRaw)
        #expect(decoded.privileges == original.privileges)
    }
}

@Suite("AccountStoreError")
struct AccountStoreErrorTests {
    @Test("duplicate / missing cases carry the offending login")
    func errorCasesCarryLogin() {
        let duplicate = AccountStoreError.duplicate(login: "admin")
        let missing = AccountStoreError.missing(login: "ghost")
        if case let .duplicate(name) = duplicate { #expect(name == "admin") } else { Issue.record("expected duplicate") }
        if case let .missing(name) = missing { #expect(name == "ghost") } else { Issue.record("expected missing") }
    }

    @Test("persistenceFailed equality includes the message")
    func persistenceFailedEquality() {
        let same = AccountStoreError.persistenceFailed(message: "disk full")
        let other = AccountStoreError.persistenceFailed(message: "disk full")
        let differentMessage = AccountStoreError.persistenceFailed(message: "disk full ")
        #expect(same == other)
        #expect(same != differentMessage)
    }
}

@Suite("AccountStore in-memory CRUD")
struct AccountStoreCRUDTests {
    @Test("get returns nil for unknown login")
    func getMissing() async {
        let store = await AccountStore(snapshotURL: nil)
        let result = await store.get("ghost")
        #expect(result == nil)
    }

    @Test("create then get returns the account; create twice throws duplicate")
    func createThenGet() async throws {
        let store = await AccountStore(snapshotURL: nil)
        let account = ServerAccount(login: "carol", password: "s3cret", nickname: "Carol", privileges: [.sendChat])
        try await store.create(account)
        let fetched = await store.get("carol")
        #expect(fetched == account)

        await #expect(throws: AccountStoreError.duplicate(login: "carol")) {
            try await store.create(account)
        }
    }

    @Test("modify replaces nickname + privileges; missing throws")
    func modifyExisting() async throws {
        let store = await AccountStore(snapshotURL: nil)
        let seeded = ServerAccount(login: "tom", password: "pw", nickname: "Tom", privileges: [.readChat])
        try await store.create(seeded)

        try await store.modify(
            login: "tom",
            password: nil,
            nickname: "Tommy",
            privileges: [.readChat, .sendChat]
        )
        let updated = await store.get("tom")
        #expect(updated?.nickname == "Tommy")
        #expect(updated?.password == "pw")             // unchanged
        #expect(updated?.privileges.contains(.sendChat) == true)

        await #expect(throws: AccountStoreError.missing(login: "ghost")) {
            try await store.modify(login: "ghost", password: nil, nickname: "x", privileges: [])
        }
    }

    @Test("modify password rules: nil keep, empty clear, otherwise replace")
    func modifyPasswordRules() async throws {
        let store = await AccountStore(snapshotURL: nil)
        try await store.create(ServerAccount(login: "tom", password: "old", nickname: "T", privileges: []))

        try await store.modify(login: "tom", password: nil, nickname: "T", privileges: [])
        #expect(await store.get("tom")?.password == "old")

        try await store.modify(login: "tom", password: "", nickname: "T", privileges: [])
        #expect(await store.get("tom")?.password == "")

        try await store.modify(login: "tom", password: "new", nickname: "T", privileges: [])
        #expect(await store.get("tom")?.password == "new")
    }

    @Test("delete removes the entry; missing throws")
    func deleteEntry() async throws {
        let store = await AccountStore(snapshotURL: nil)
        try await store.create(ServerAccount(login: "tom", password: "pw", nickname: "Tom", privileges: []))
        try await store.delete("tom")
        #expect(await store.get("tom") == nil)
        await #expect(throws: AccountStoreError.missing(login: "tom")) {
            try await store.delete("tom")
        }
    }

    @Test("seeds populate the store on first init")
    func seedsAreApplied() async {
        let seed = ServerAccount(login: "admin", password: "admin", nickname: "Administrator", privileges: [.canBroadcast])
        let store = await AccountStore(snapshotURL: nil, seeds: [seed])
        let fetched = await store.get("admin")
        #expect(fetched == seed)
        let all = await store.all()
        #expect(all.count == 1)
    }
}

@Suite("AccountStore JSON snapshot")
struct AccountStoreSnapshotTests {
    @Test("snapshot survives a fresh store init pointing at the same URL")
    func snapshotRoundTrip() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeidrunAccountStoreTest-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = temporaryDirectory.appendingPathComponent("accounts.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstStore = await AccountStore(snapshotURL: snapshotURL)
        try await firstStore.create(ServerAccount(
            login: "carol",
            password: "s3cret",
            nickname: "Carol",
            privileges: [.sendChat, .readNews]
        ))
        try await firstStore.create(ServerAccount(
            login: "tom",
            password: "p",
            nickname: "Tom",
            privileges: [.readChat]
        ))
        try await firstStore.delete("tom")

        let secondStore = await AccountStore(snapshotURL: snapshotURL)
        let reloaded = await secondStore.get("carol")
        #expect(reloaded?.nickname == "Carol")
        #expect(reloaded?.privileges.contains(.sendChat) == true)
        #expect(await secondStore.get("tom") == nil)
    }

    @Test("seeds are written to disk on first init when no snapshot exists")
    func seedsWrittenOnFirstInit() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeidrunAccountStoreTest-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = temporaryDirectory.appendingPathComponent("accounts.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let seed = ServerAccount(login: "admin", password: "admin", nickname: "Administrator", privileges: [.canBroadcast])
        _ = await AccountStore(snapshotURL: snapshotURL, seeds: [seed])

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        let secondStore = await AccountStore(snapshotURL: snapshotURL)
        #expect(await secondStore.get("admin") == seed)
    }
}
