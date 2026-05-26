import Foundation
import Testing
@testable import HeidrunCore

@Suite("ConnectionSettings")
struct ConnectionSettingsTests {
    @Test("login defaults to empty string")
    func loginDefaultsEmpty() {
        let settings = ConnectionSettings(name: "x", address: "x")
        #expect(settings.login.isEmpty)
    }

    @Test("login round-trips through init")
    func loginRoundTrips() {
        let settings = ConnectionSettings(name: "x", address: "x", login: "guest")
        #expect(settings.login == "guest")
    }

    @Test("two settings with different logins are not equal")
    func loginIsPartOfIdentity() {
        let alice = ConnectionSettings(name: "x", address: "x", login: "alice")
        let bob = ConnectionSettings(name: "x", address: "x", login: "bob")
        #expect(alice != bob)
    }

    @Test("pinnedCertificateSHA256 round-trips through Codable")
    func pinRoundTrips() throws {
        var settings = ConnectionSettings(name: "S", address: "h", useTLS: true)
        settings.pinnedCertificateSHA256 = "abc123"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ConnectionSettings.self, from: data)
        #expect(decoded.pinnedCertificateSHA256 == "abc123")
    }

    @Test("v1 JSON without the pin key decodes to nil")
    func oldBookmarkDecodesNilPin() throws {
        let json = #"""
        {"name":"S","address":"h","port":5500,"nickname":"","login":"",
         "icon":0,"useDefaultUserInfo":true,"autoConnectFavorite":false,
         "assignFavoriteShortcut":false}
        """#
        let decoded = try JSONDecoder().decode(
            ConnectionSettings.self, from: Data(json.utf8))
        #expect(decoded.pinnedCertificateSHA256 == nil)
        #expect(decoded.useTLS == false)
    }
}
