import Testing
import Foundation
@testable import HeidrunCore

@Suite("TrackerRegistrationCodec")
struct TrackerRegistrationCodecTests {

    /// Golden vector lifted from `jhalter/mobius/hotline/tracker_test.go`.
    /// If a future change breaks this assertion, the packet has drifted
    /// from the mobius wire format and existing trackers (which work with
    /// mobius) will reject our heartbeats.
    @Test("encode matches the mobius golden vector")
    func mobiusVector() {
        let registration = TrackerRegistration(
            port: 16,
            userCount: 2,
            tlsPort: 0,
            passID: 1,
            name: "Test Serv",
            description: "Fooz",
            password: ""
        )

        let expected = Data([
            0x00, 0x01,                                         // version = 1
            0x00, 0x10,                                         // port = 16
            0x00, 0x02,                                         // userCount = 2
            0x00, 0x00,                                         // tlsPort = 0
            0x00, 0x00, 0x00, 0x01,                             // passID = 1
            0x09,                                               // nameLen = 9
            0x54, 0x65, 0x73, 0x74, 0x20, 0x53, 0x65, 0x72, 0x76,   // "Test Serv"
            0x04,                                               // descLen = 4
            0x46, 0x6f, 0x6f, 0x7a,                             // "Fooz"
            0x00                                                // passLen = 0
        ])

        #expect(TrackerRegistrationCodec.encode(registration) == expected)
    }

    @Test("non-empty password is length-prefixed and appended last")
    func nonEmptyPassword() {
        let registration = TrackerRegistration(
            port: 5500,
            userCount: 0,
            passID: 0,
            name: "X",
            description: "Y",
            password: "secret"
        )

        let bytes = TrackerRegistrationCodec.encode(registration)

        // 12-byte prefix + (1+1) name + (1+1) desc + (1+6) password = 23.
        #expect(bytes.count == 23)
        // Tail = passLen byte + "secret".
        #expect(bytes.suffix(7) == Data([0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74]))
    }

    @Test("name longer than 255 bytes truncates silently rather than rejecting")
    func nameTruncation() {
        let registration = TrackerRegistration(
            port: 5500,
            userCount: 0,
            passID: 0,
            name: String(repeating: "a", count: 300),
            description: "",
            password: ""
        )

        let bytes = TrackerRegistrationCodec.encode(registration)
        // Length byte after the 12-byte prefix should clamp at 255.
        #expect(bytes[12] == 0xFF)
        // 12 prefix + 1 nameLen + 255 name + 1 descLen + 0 + 1 passLen + 0 = 270
        #expect(bytes.count == 270)
    }

    @Test("tlsPort and passID round-trip as big-endian fields")
    func bigEndianFields() {
        let registration = TrackerRegistration(
            port: 0x1234,
            userCount: 0x00FF,
            tlsPort: 0xABCD,
            passID: 0xDEAD_BEEF,
            name: "",
            description: "",
            password: ""
        )

        let bytes = TrackerRegistrationCodec.encode(registration)
        // Prefix: 0001 1234 00FF ABCD DEAD BEEF
        let expectedPrefix = Data([
            0x00, 0x01,
            0x12, 0x34,
            0x00, 0xFF,
            0xAB, 0xCD,
            0xDE, 0xAD, 0xBE, 0xEF
        ])
        #expect(bytes.prefix(12) == expectedPrefix)
    }
}
