import Foundation
import Testing
import HeidrunCore
@testable import HeidrunTestServerKit

@Suite("Account admin transactions")
struct AccountTransactionsTests {

    private func makeServer(seeded: [ServerAccount] = []) async throws -> TestServerInstance {
        let store = AccountStore(seeds: seeded)
        let state = ServerState(advertisedVersion: 185, accounts: store)
        return try TestServerInstance.startEphemeral(state: state)
    }

    private func connectLoggedIn(server: TestServerInstance, name: String = "tester") async throws -> any HotlineClient {
        let settings = ConnectionSettings(
            name: "TestServer",
            address: "127.0.0.1",
            port: server.controlPort
        )
        let client = try await HotlineNetworkClient.connect(settings: settings)
        try await client.login(name: name, password: "", nickname: name, icon: 1)
        return client
    }

    @Test("createLogin then openLogin round-trips the privileges")
    func createThenOpen() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let client = try await connectLoggedIn(server: server)

        try await client.createLogin(
            name: "carol",
            password: "pw",
            nickname: "Carol",
            privileges: [.uploadFiles, .downloadFiles, .sendChat]
        )

        let (nickname, privileges) = try await client.openLogin("carol")
        #expect(nickname == "Carol")
        #expect(privileges.contains(.uploadFiles))
        #expect(privileges.contains(.sendChat))
        #expect(!privileges.contains(.canBroadcast))
    }

    @Test("createLogin on an existing login replies with an error")
    func duplicateCreate() async throws {
        let seed = ServerAccount(login: "carol", password: "pw", nickname: "C", privileges: [])
        let server = try await makeServer(seeded: [seed])
        defer { server.stop() }
        let client = try await connectLoggedIn(server: server)

        await #expect(throws: (any Error).self) {
            try await client.createLogin(name: "carol", password: "pw", nickname: "C", privileges: [])
        }
    }

    @Test("modifyLogin updates fields; nil password keeps existing")
    func modifyKeepsPassword() async throws {
        let seed = ServerAccount(login: "tom", password: "old", nickname: "Tom", privileges: [.readChat])
        let server = try await makeServer(seeded: [seed])
        defer { server.stop() }
        let client = try await connectLoggedIn(server: server)

        try await client.modifyLogin(
            name: "tom",
            password: nil,
            nickname: "Tommy",
            privileges: [.readChat, .sendChat]
        )
        let stored = await server.state.accounts.get("tom")
        #expect(stored?.password == "old")
        #expect(stored?.nickname == "Tommy")
        #expect(stored?.privileges.contains(.sendChat) == true)
    }

    @Test("modifyLogin with empty password clears the password")
    func modifyEmptyPasswordClears() async throws {
        let seed = ServerAccount(login: "tom", password: "old", nickname: "Tom", privileges: [])
        let server = try await makeServer(seeded: [seed])
        defer { server.stop() }
        let client = try await connectLoggedIn(server: server)

        try await client.modifyLogin(name: "tom", password: "", nickname: "Tom", privileges: [])
        #expect(await server.state.accounts.get("tom")?.password == "")
    }

    @Test("deleteLogin removes the account; double-delete errors")
    func deleteRemoves() async throws {
        let seed = ServerAccount(login: "carol", password: "pw", nickname: "C", privileges: [])
        let server = try await makeServer(seeded: [seed])
        defer { server.stop() }
        let client = try await connectLoggedIn(server: server)

        try await client.deleteLogin("carol")
        #expect(await server.state.accounts.get("carol") == nil)

        await #expect(throws: (any Error).self) {
            try await client.deleteLogin("carol")
        }
    }

    @Test("openLogin on unknown account errors")
    func openMissingErrors() async throws {
        let server = try await makeServer()
        defer { server.stop() }
        let client = try await connectLoggedIn(server: server)
        await #expect(throws: (any Error).self) {
            _ = try await client.openLogin("ghost")
        }
    }
}
