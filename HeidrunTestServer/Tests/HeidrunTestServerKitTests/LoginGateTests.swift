import Foundation
import Testing
import HeidrunCore
@testable import HeidrunTestServerKit

@Suite("Login gate")
struct LoginGateTests {

    private func makeServer(seeded: [ServerAccount]) async throws -> TestServerInstance {
        let store = AccountStore(seeds: seeded)
        let state = ServerState(advertisedVersion: 185, accounts: store)
        return try TestServerInstance.startEphemeral(state: state)
    }

    private func connectAndLogin(
        server: TestServerInstance,
        loginName: String,
        password: String,
        nickname: String = "tester"
    ) async throws -> any HotlineClient {
        let settings = ConnectionSettings(
            name: "TestServer",
            address: "127.0.0.1",
            port: server.controlPort
        )
        let client = try await HotlineNetworkClient.connect(settings: settings)
        try await client.login(name: loginName, password: password, nickname: nickname, icon: 1)
        return client
    }

    @Test("unknown login falls through to wide-open behavior")
    func unknownLoginAllowed() async throws {
        let server = try await makeServer(seeded: [])
        defer { server.stop() }
        // "anon" is not in the (empty) account roster — should fall through.
        _ = try await connectAndLogin(server: server, loginName: "anon", password: "whatever")
    }

    @Test("known login with wrong password is rejected")
    func wrongPasswordRejected() async throws {
        let seed = ServerAccount(login: "admin", password: "admin", nickname: "Admin", privileges: [.canBroadcast])
        let server = try await makeServer(seeded: [seed])
        defer { server.stop() }
        await #expect(throws: (any Error).self) {
            try await connectAndLogin(server: server, loginName: "admin", password: "wrong")
        }
    }

    @Test("known login with correct password applies stored privileges (visible via connected users)")
    func correctPasswordAppliesPrivileges() async throws {
        let seed = ServerAccount(
            login: "admin",
            password: "admin",
            nickname: "Administrator",
            privileges: [.canBroadcast, .createUser, .deleteUser]
        )
        let server = try await makeServer(seeded: [seed])
        defer { server.stop() }
        _ = try await connectAndLogin(server: server, loginName: "admin", password: "admin", nickname: "Administrator")
        let connectedUsers = await server.state.connectedUsers
        let adminUser = try #require(connectedUsers.first(where: { $0.nickname == "Administrator" }))
        #expect(adminUser.privileges.contains(.canBroadcast))
        #expect(adminUser.privileges.contains(.createUser))
    }
}
