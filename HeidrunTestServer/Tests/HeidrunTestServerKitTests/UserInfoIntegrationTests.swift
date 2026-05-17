import Foundation
import Testing
import HeidrunCore
import HeidrunTestServerKit

/// End-to-end check that `fetchUserInfo` against the test server
/// returns the gate.tastybytes.org-style profile dump in field 101
/// plus the separate login (field 105) so the Get-Info sheet's
/// Account row populates without having to scrape the dump.
@Suite("HotlineNetworkClient ↔ TestServerInstance — user info")
struct UserInfoIntegrationTests {

    @Test("fetchUserInfo on self returns a profile dump with name, login, version, uid, icon — and a populated accountLogin field")
    func selfUserInfoIncludesProfileDump() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }

        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.controlPort
            )
        )
        try await client.login(name: "admin", password: "admin", nickname: "silver:box", icon: 131)
        defer { Task { await client.disconnect() } }

        let socket = await client.connectionInfo.connectionSocket
        let info = try await client.fetchUserInfo(socket: socket)

        #expect(info.user.socket == socket)
        #expect(info.user.nickname == "silver:box")
        #expect(info.user.icon == 131)
        // The Account row is what the user actually called out — it
        // must populate from field 105, not require parsing the dump.
        #expect(info.accountLogin == "admin")

        // The profile dump itself should carry the labeled rows the
        // Get-Info sheet renders monospaced. We don't pin exact byte
        // counts (the `host:port` line varies per test run) but we do
        // check the labels the user saw on gate.tastybytes.org.
        let profile = info.infoText
        #expect(profile.contains("name: silver:box"))
        #expect(profile.contains("login: admin"))
        #expect(profile.contains("icon: 131"))
        #expect(profile.contains("uid: \(socket)"))
        #expect(profile.contains(" - Downloads -"))
        #expect(profile.contains(" - Uploads -"))
    }

    @Test("a guest login (no account) renders the dump with login = guest")
    func guestUserInfoLandsAsGuest() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }

        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.controlPort
            )
        )
        try await client.login(name: "", password: "", nickname: "drifter", icon: 4)
        defer { Task { await client.disconnect() } }

        let socket = await client.connectionInfo.connectionSocket
        let info = try await client.fetchUserInfo(socket: socket)

        #expect(info.accountLogin == "guest")
        #expect(info.infoText.contains("login: guest"))
    }
}
