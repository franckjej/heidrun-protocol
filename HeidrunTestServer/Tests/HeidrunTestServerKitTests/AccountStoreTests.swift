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
}
