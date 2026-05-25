import Testing
import Foundation
@testable import HeidrunCore

@Suite("TrackerRegistrationCodec")
struct TrackerRegistrationCodecTests {

    /// Golden vector for the original Hotline tracker registration format
    /// (`hldoc.txt:2455–2498`): 12-byte prefix with a reserved `0x0000`
    /// field, name + description, then the new-version `login` + `password`
    /// trailing (both empty for a public tracker → two `0x00` length bytes).
    @Test("encode matches the hldoc spec layout for a public tracker")
    func specVector() {
        let registration = TrackerRegistration(
            port: 16,
            userCount: 2,
            passID: 1,
            name: "Test Serv",
            description: "Fooz"
        )

        let expected = Data([
            0x00, 0x01,                                         // version = 1
            0x00, 0x10,                                         // port = 16
            0x00, 0x02,                                         // userCount = 2
            0x00, 0x00,                                         // reserved = 0
            0x00, 0x00, 0x00, 0x01,                             // passID = 1
            0x09,                                               // nameLen = 9
            0x54, 0x65, 0x73, 0x74, 0x20, 0x53, 0x65, 0x72, 0x76,   // "Test Serv"
            0x04,                                               // descLen = 4
            0x46, 0x6f, 0x6f, 0x7a,                             // "Fooz"
            0x00,                                               // loginLen = 0
            0x00                                                // passLen = 0
        ])

        #expect(TrackerRegistrationCodec.encode(registration) == expected)
    }

    @Test("login and password are length-prefixed in spec order (login then password)")
    func newVersionTrailing() {
        let registration = TrackerRegistration(
            port: 5500,
            userCount: 0,
            passID: 0,
            name: "X",
            description: "Y",
            login: "user",
            password: "secret"
        )

        let bytes = TrackerRegistrationCodec.encode(registration)

        // 12 prefix + (1+1) name + (1+1) desc + (1+4) login + (1+6) password = 28.
        #expect(bytes.count == 28)
        // Tail (12 bytes) = loginLen + "user" + passLen + "secret".
        #expect(bytes.suffix(12) == Data([
            0x04, 0x75, 0x73, 0x65, 0x72,
            0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74
        ]))
    }

    @Test("the reserved field is always 0, even when other fields are set")
    func reservedFieldIsZero() {
        let registration = TrackerRegistration(
            port: 0x1234,
            userCount: 0x00FF,
            passID: 0xDEAD_BEEF,
            name: "",
            description: ""
        )

        let bytes = TrackerRegistrationCodec.encode(registration)
        // Prefix: 0001 1234 00FF 0000 DEADBEEF — field 4 is the reserved 0x0000.
        let expectedPrefix = Data([
            0x00, 0x01,
            0x12, 0x34,
            0x00, 0xFF,
            0x00, 0x00,
            0xDE, 0xAD, 0xBE, 0xEF
        ])
        #expect(bytes.prefix(12) == expectedPrefix)
    }

    @Test("name longer than 255 bytes truncates silently rather than rejecting")
    func nameTruncation() {
        let registration = TrackerRegistration(
            port: 5500,
            userCount: 0,
            passID: 0,
            name: String(repeating: "a", count: 300),
            description: ""
        )

        let bytes = TrackerRegistrationCodec.encode(registration)
        // Length byte after the 12-byte prefix should clamp at 255.
        #expect(bytes[12] == 0xFF)
        // 12 prefix + 1 nameLen + 255 name + 1 descLen + 1 loginLen + 1 passLen = 271.
        #expect(bytes.count == 271)
    }

    @Test("strings encode as 8-bit ASCII — no high-bit (MacRoman) bytes")
    func asciiEncoding() {
        let registration = TrackerRegistration(
            port: 0,
            userCount: 0,
            passID: 0,
            name: "Café",
            description: ""
        )

        let bytes = TrackerRegistrationCodec.encode(registration)
        // "Café" → "Caf?" : 'é' (MacRoman 0x8E) becomes ASCII '?' (0x3F),
        // never a high-bit byte. Deterministic across platforms.
        #expect(bytes[12] == 0x04)
        #expect(bytes[13 ..< 17] == Data([0x43, 0x61, 0x66, 0x3F]))
    }
}
