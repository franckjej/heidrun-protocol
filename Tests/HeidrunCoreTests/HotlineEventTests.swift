import Foundation
import Testing
@testable import HeidrunCore

@Suite("HotlineEvent / HotlineError")
struct HotlineEventTests {
    @Test("HotlineEvent equality covers associated values")
    func eventEqualityHasAssociatedValues() {
        let a: HotlineEvent = .chatReceived(chat: nil, message: "hi", isAction: false)
        let b: HotlineEvent = .chatReceived(chat: nil, message: "hi", isAction: false)
        let c: HotlineEvent = .chatReceived(chat: nil, message: "hi", isAction: true)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("HotlineError prints something useful for each case")
    func errorDescriptions() {
        #expect(String(describing: HotlineError.notConnected) == "not connected")
        #expect(String(describing: HotlineError.cancelled)    == "cancelled")
        #expect(String(describing: HotlineError.timedOut)     == "timed out")
        #expect(
            String(describing: HotlineError.serverError(id: 42, message: "denied"))
                == "server error 42: denied"
        )
        #expect(
            String(describing: HotlineError.serverError(id: 7, message: nil))
                == "server error 7"
        )
    }

    @Test("ConnectionSettings defaults to port 5500 and useDefaultUserInfo == true")
    func connectionSettingsDefaults() {
        let settings = ConnectionSettings(name: "Test", address: "test.example.com")
        #expect(settings.port == 5500)
        #expect(settings.useDefaultUserInfo)
        #expect(!settings.autoConnectFavorite)
    }

    @Test("HostColor stores RGBA verbatim")
    func hostColor() {
        let color = HostColor(red: 0.1, green: 0.5, blue: 0.9)
        #expect(color.alpha == 1.0)
        #expect(color.red == 0.1)
    }
}
