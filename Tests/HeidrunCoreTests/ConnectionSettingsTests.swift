import Foundation
import Testing
@testable import HeidrunCore

@Suite("ConnectionSettings")
struct ConnectionSettingsTests {
    @Test("login defaults to empty string")
    func loginDefaultsEmpty() {
        let settings = ConnectionSettings(name: "x", address: "x")
        #expect(settings.login == "")
    }

    @Test("login round-trips through init")
    func loginRoundTrips() {
        let settings = ConnectionSettings(name: "x", address: "x", login: "guest")
        #expect(settings.login == "guest")
    }

    @Test("two settings with different logins are not equal")
    func loginIsPartOfIdentity() {
        let a = ConnectionSettings(name: "x", address: "x", login: "alice")
        let b = ConnectionSettings(name: "x", address: "x", login: "bob")
        #expect(a != b)
    }
}
