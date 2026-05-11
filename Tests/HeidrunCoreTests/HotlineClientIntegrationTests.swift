import Foundation
import Testing
@testable import HeidrunCore

/// End-to-end tests that wire a real `HotlineNetworkClient` to a local
/// `MiniHotlineServer` over loopback. They prove the actual bytes the
/// client puts on the wire match what a Hotline server expects, beyond
/// the unit-level codec tests.
@Suite("HotlineNetworkClient + MiniHotlineServer")
struct HotlineClientIntegrationTests {

    /// Just the magic-byte handshake. Confirms the client sends
    /// "TRTPHOTL\0\1\0\2" and accepts the 8-byte server OK.
    @Test("magic handshake completes successfully")
    func handshakeSmoke() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let acceptedConnection = server.acceptNextConnection()
        async let client = HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.port
            )
        )

        let conn = try await acceptedConnection
        let magic = try await conn.receiveExactly(12)
        #expect(Array(magic) == [
            0x54, 0x52, 0x54, 0x50, // "TRTP"
            0x48, 0x4F, 0x54, 0x4C, // "HOTL"
            0x00, 0x01,
            0x00, 0x02
        ])
        try await conn.sendAsync(Data([
            0x54, 0x52, 0x54, 0x50,
            0x00, 0x00, 0x00, 0x00
        ]))

        let c = try await client
        await c.disconnect()
        conn.cancel()
    }

    /// Login round-trip. Verifies the wire fields the client sends
    /// (XOR-obfuscated login/password, nickname, icon, clientVersion)
    /// and that the client absorbs the server's clientVersion reply.
    @Test("login round-trips with the right fields")
    func loginRoundTrips() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.port
            )
        )
        let sc = try await serverConnTask

        async let serverWork: Void = {
            let packet = try await sc.readPacket()
            #expect(packet.header.transactionID == 107)
            #expect(packet.header.errorID == 0)

            let login    = packet.fields.obfuscatedString(.login)
            let password = packet.fields.obfuscatedString(.password)
            let nickname = packet.fields.string(.nickname)
            let icon     = packet.fields.uint16(.icon)
            let version  = packet.fields.uint16(.clientVersion)

            #expect(login    == "jens")
            #expect(password == "hunter2")
            #expect(nickname == "Heidrun")
            #expect(icon     == 42)
            #expect(version  == 151)

            try await sc.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber,
                fields: [.uint16(.clientVersion, 199)]
            )
        }()

        try await client.login(
            name: "jens",
            password: "hunter2",
            nickname: "Heidrun",
            icon: 42
        )
        try await serverWork

        await client.disconnect()
        sc.close()
    }

    /// `sendChat` is a no-reply transaction (105). Confirm the bytes
    /// on the wire match: message string + isAction parameter.
    @Test("sendChat sends the expected fields")
    func sendChatBytes() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.port
            )
        )
        let sc = try await serverConnTask

        try await client.sendChat("hello world", in: nil, isAction: false)

        let packet = try await sc.readPacket()
        #expect(packet.header.transactionID == 105)
        #expect(packet.fields.string(.message) == "hello world")
        #expect(packet.fields.uint16(.parameter) == 0)

        await client.disconnect()
        sc.close()
    }

    /// `fetchUserList` (300) returns the list of `userListEntry` fields
    /// in the reply, in order. Build two encoded entries on the server
    /// side and assert the client decodes both.
    @Test("fetchUserList returns the encoded users")
    func fetchUserListReturnsUsers() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.port
            )
        )
        let sc = try await serverConnTask

        async let serverWork: Void = {
            let packet = try await sc.readPacket()
            #expect(packet.header.transactionID == 300)
            try await sc.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber,
                fields: [
                    PacketField(key: .userListEntry, data: encodedUser(
                        socket: 7, icon: 12, status: 0, nickname: "Alice"
                    )),
                    PacketField(key: .userListEntry, data: encodedUser(
                        socket: 8, icon: 13, status: 0, nickname: "Bob"
                    ))
                ]
            )
        }()

        let users = try await client.fetchUserList()
        try await serverWork

        #expect(users.count == 2)
        #expect(users[0].socket == 7)
        #expect(users[0].nickname == "Alice")
        #expect(users[1].socket == 8)
        #expect(users[1].nickname == "Bob")

        await client.disconnect()
        sc.close()
    }

    /// Server pushes an unsolicited `broadcast` (transID 355). The
    /// client's `events` stream should deliver `.broadcastReceived`.
    @Test("server-pushed broadcast surfaces via the events stream")
    func broadcastEventDelivered() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: server.port
            )
        )
        let sc = try await serverConnTask

        let eventTask = Task { () -> String? in
            for await event in client.events {
                if case let .broadcastReceived(message) = event {
                    return message
                }
            }
            return nil
        }

        try await sc.sendPush(
            transactionID: 355,
            fields: [.string(.message, "server going down at midnight")]
        )

        let received = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { await eventTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }

        #expect(received == "server going down at midnight")

        eventTask.cancel()
        await client.disconnect()
        sc.close()
    }

    // MARK: - Helpers

    /// Encode a userListEntry blob the way Hotline puts it on the wire.
    private func encodedUser(
        socket: UInt16,
        icon: UInt16,
        status: UInt16,
        nickname: String
    ) -> Data {
        var data = Data()
        data.appendBigEndian(socket)
        data.appendBigEndian(icon)
        data.appendBigEndian(status)
        let nick = nickname.data(using: .macOSRoman) ?? Data()
        data.appendBigEndian(UInt16(nick.count))
        data.append(nick)
        return data
    }
}
