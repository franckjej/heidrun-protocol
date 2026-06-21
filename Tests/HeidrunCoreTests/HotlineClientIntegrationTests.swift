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
            // Option 2: the nickname rides IN the login packet again. The
            // client always advertises CAPABILITY_TEXT_ENCODING, so the nick
            // is UTF-8-encoded; "Heidrun" is ASCII so it round-trips either
            // way and reads back under macOS Roman too.
            let packet = try await sc.readPacket()
            #expect(packet.header.transactionID == 107)
            #expect(packet.header.errorID == 0)

            let login    = packet.fields.obfuscatedString(.login)
            let password = packet.fields.obfuscatedString(.password)
            let nickname = packet.fields.string(.nickname, encoding: .utf8)
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

    /// Option 2: the client always advertises CAPABILITY_TEXT_ENCODING, so the
    /// nickname rides IN the login(107) packet UTF-8-encoded. A non-ASCII nick
    /// must therefore arrive as UTF-8 bytes in the login packet — no post-login
    /// TX 304. (The server decodes the login nick as UTF-8 when the login
    /// caps include textEncoding.)
    @Test("login packet carries the nickname UTF-8-encoded")
    func loginNickIsUTF8InLoginPacket() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask

        // A nickname with a character that round-trips differently under
        // macOS Roman vs UTF-8 (U+00E9 é). UTF-8 encodes it as two bytes.
        let accentedNick = "café"

        async let serverWork: Void = {
            let loginPacket = try await sc.readPacket()
            #expect(loginPacket.header.transactionID == 107)
            // The client advertises textEncoding in its login caps.
            let advertised = loginPacket.fields.uint16(.capabilities) ?? 0
            #expect(advertised & CapabilityFlags.textEncoding.rawValue != 0)
            // Nickname rides in the login packet, UTF-8-encoded.
            #expect(loginPacket.fields.string(.nickname, encoding: .utf8) == accentedNick)
            // And the raw bytes must be the UTF-8 form (é = 0xC3 0xA9),
            // not the single-byte macOS Roman form.
            let rawNick = loginPacket.fields.first(.nickname)?.data
            #expect(rawNick == accentedNick.data(using: .utf8))
            // Echo the textEncoding capability bit on the reply.
            try await sc.sendReply(
                transactionID: loginPacket.header.transactionID,
                taskNumber: loginPacket.header.taskNumber,
                fields: [.uint16(.capabilities, CapabilityFlags.textEncoding.rawValue)]
            )
        }()

        try await client.login(
            name: "jens", password: "hunter2", nickname: accentedNick, icon: 5
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

    @Test("listFiles decodes legacy + large-file entries in order")
    func listFilesDecodesLargeEntries() async throws {
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
        let serverConn = try await serverConnTask

        let small = RemoteFile(name: "small.txt", size: 1234)
        let huge = RemoteFile(name: "huge.bin", size: 0x2_0000_0000)
        let (hugeEntry, hugeSize64) = FileListEntryCodec.encodeLargeFile(huge)

        async let serverWork: Void = {
            let packet = try await serverConn.readPacket()
            #expect(packet.header.transactionID == 200)
            try await serverConn.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber,
                fields: [
                    FileListEntryCodec.encode(small),
                    hugeEntry,
                    hugeSize64
                ]
            )
        }()

        let files = try await client.listFiles(at: RemotePath())
        try await serverWork

        #expect(files.count == 2)
        #expect(files[0].name == "small.txt")
        #expect(files[0].size == 1234)
        #expect(files[1].name == "huge.bin")
        #expect(files[1].size == 0x2_0000_0000)

        await client.disconnect()
        serverConn.close()
    }

    /// `fetchUserInfo` (303) parses the server's reply into a
    /// `UserInfo` value carrying the nickname, status flags, account
    /// login (field 105, XOR-obfuscated on the wire), and the
    /// free-form info text the user wrote into their profile pane.
    @Test("fetchUserInfo decodes nickname, account login (obfuscated), status, and info text")
    func fetchUserInfoDecodesReply() async throws {
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
        let serverConn = try await serverConnTask

        async let serverWork: Void = {
            let packet = try await serverConn.readPacket()
            #expect(packet.header.transactionID == 303)
            #expect(packet.fields.uint16(.socket) == 42)
            try await serverConn.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber,
                fields: [
                    .string(.nickname, "Erika"),
                    .uint16(.icon, 128),
                    // Status low byte = away | admin = 0b0000_0011 = 0x03.
                    .uint16(.status, 0x0003),
                    .obfuscatedString(.login, "erika.account"),
                    .string(.message, "Friendly fish.\nBased in Stockholm.")
                ]
            )
        }()

        let info = try await client.fetchUserInfo(socket: 42)
        try await serverWork

        #expect(info.user.socket == 42)
        #expect(info.user.nickname == "Erika")
        #expect(info.user.icon == 128)
        #expect(info.user.status.flags.contains(.away))
        #expect(info.user.status.flags.contains(.admin))
        #expect(info.accountLogin == "erika.account")
        #expect(info.infoText == "Friendly fish.\nBased in Stockholm.")

        await client.disconnect()
        serverConn.close()
    }

    /// Some Hotline servers send field 105 on the 303 reply as plain
    /// text rather than the XOR-obfuscated form used on auth-side
    /// transactions. The decoder sniffs the byte distribution and
    /// picks the right path; a plain "admin" must come back as
    /// "admin", not as five high-bit garbage characters.
    @Test("fetchUserInfo decodes plain-text login (server doesn't obfuscate field 105 on the reply)")
    func fetchUserInfoDecodesPlainLogin() async throws {
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
        let serverConn = try await serverConnTask

        async let serverWork: Void = {
            let packet = try await serverConn.readPacket()
            try await serverConn.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber,
                fields: [
                    .string(.nickname, "Admin"),
                    .uint16(.icon, 0),
                    .uint16(.status, 0x0002),
                    // Plain "admin" — high bit clear on every byte.
                    .string(.login, "admin"),
                    .string(.message, "")
                ]
            )
        }()

        let info = try await client.fetchUserInfo(socket: 1)
        try await serverWork

        #expect(info.accountLogin == "admin")

        await client.disconnect()
        serverConn.close()
    }

    /// Servers that omit field 105 on the 303 reply (some guest-only
    /// setups) still return a useful `UserInfo` — `accountLogin` falls
    /// back to the empty string and the sheet treats that as "—".
    @Test("fetchUserInfo tolerates a server that omits field 105")
    func fetchUserInfoToleratesMissingLogin() async throws {
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
        let serverConn = try await serverConnTask

        async let serverWork: Void = {
            let packet = try await serverConn.readPacket()
            try await serverConn.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber,
                fields: [
                    .string(.nickname, "Guest"),
                    .uint16(.icon, 0),
                    .uint16(.status, 0x0000),
                    .string(.message, "")
                ]
            )
        }()

        let info = try await client.fetchUserInfo(socket: 7)
        try await serverWork

        #expect(info.accountLogin.isEmpty)
        #expect(info.user.nickname == "Guest")
        #expect(info.infoText.isEmpty)

        await client.disconnect()
        serverConn.close()
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
            return first
        }

        #expect(received == "server going down at midnight")

        eventTask.cancel()
        await client.disconnect()
        sc.close()
    }

    @Test("a public chat subject push (TX 119, Chat ID 0) is recorded on connectionInfo")
    func publicChatSubjectRecorded() async throws {
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

        // Wait for the decode to fire — the read loop records the topic
        // before it yields the event, so once we see the event the
        // recording has happened.
        let eventTask = Task { () -> String? in
            for await event in client.events {
                if case let .privateChatSubjectChanged(_, subject) = event {
                    return subject
                }
            }
            return nil
        }

        try await sc.sendPush(
            transactionID: 119,
            fields: [
                PacketField(key: .chatReference, data: Data([0, 0, 0, 0])),
                .string(.chatSubject, "Heidrun's Inn")
            ]
        )

        let received = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { await eventTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return first
        }
        #expect(received == "Heidrun's Inn")

        let info = await client.connectionInfo
        #expect(info.publicChatSubject == "Heidrun's Inn")

        eventTask.cancel()
        await client.disconnect()
        sc.close()
    }

    @Test("login sends the userEmoji field as UTF-8")
    func loginSendsEmoji() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask

        async let serverWork: Void = {
            let packet = try await sc.readPacket()
            #expect(packet.header.transactionID == 107)
            #expect(packet.fields.uint16(.icon) == 7)
            #expect(packet.fields.string(.userEmoji, encoding: .utf8) == "🎸")
            try await sc.sendReply(
                transactionID: packet.header.transactionID,
                taskNumber: packet.header.taskNumber
            )
        }()

        try await client.login(name: "j", password: "p", nickname: "N", icon: 7, emoji: "🎸")
        try await serverWork
        await client.disconnect()
        sc.close()
    }

    @Test("changeNickname sends emoji, and an empty string to clear it")
    func changeNicknameSendsEmoji() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask

        async let serverWork: Void = {
            let setPkt = try await sc.readPacket()
            #expect(setPkt.header.transactionID == 304)
            #expect(setPkt.fields.string(.userEmoji, encoding: .utf8) == "🎸")
            let clearPkt = try await sc.readPacket()
            #expect(clearPkt.header.transactionID == 304)
            #expect(clearPkt.fields.string(.userEmoji, encoding: .utf8) == "")
        }()

        try await client.changeNickname("N", icon: 7, emoji: "🎸", persist: false)
        try await client.changeNickname("N", icon: 7, emoji: "", persist: false)
        try await serverWork
        await client.disconnect()
        sc.close()
    }

    @Test("userChanged push decodes the userEmoji field")
    func userChangedDecodesEmoji() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask
        let events = client.events   // subscribe before the push

        try await sc.sendPush(transactionID: 301, fields: [
            .uint16(.socket, 9),
            .uint16(.icon, 3),
            .uint16(.status, 0),
            .string(.nickname, "Frank", encoding: .macOSRoman),
            .string(.userEmoji, "🎸", encoding: .utf8)
        ])

        var received: User?
        for await event in events {
            if case let .userChanged(user) = event { received = user; break }
        }
        #expect(received?.socket == 9)
        #expect(received?.emoji == "🎸")

        await client.disconnect()
        sc.close()
    }

    /// HXD-family servers reuse TX 354 to push the connected user's access
    /// privileges right after login — an 8-byte `privileges` (110) field and
    /// NO `userListEntry` (300) objects. A privs-only 354 must NOT surface as
    /// `.userListReceived`, because the VM treats that as a full-roster
    /// snapshot and an empty one wipes the seeded user list.
    @Test("a privileges-only TX 354 push does not emit an (empty) userListReceived")
    func privilegesOnly354DoesNotEmitUserList() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask
        let events = client.events   // subscribe before the pushes

        // 1) The HXD privileges push (no userListEntry objects).
        try await sc.sendPush(transactionID: 354, fields: [
            PacketField(key: .privileges, data: Data(repeating: 0xFF, count: 8))
        ])
        // 2) A userChanged sentinel we WILL observe. If a spurious
        //    userListReceived was emitted for the privs push, it is queued
        //    ahead of this and we'd see it first.
        try await sc.sendPush(transactionID: 301, fields: [
            .uint16(.socket, 9),
            .uint16(.icon, 3),
            .uint16(.status, 0),
            .string(.nickname, "Frank", encoding: .macOSRoman)
        ])

        let sawUserList = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in events {
                    if case .userListReceived = event { return true }
                    if case .userChanged = event { return false }   // sentinel
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(sawUserList == false)

        await client.disconnect()
        sc.close()
    }

    /// Regression guard for the fix above: a TX 354 that actually carries
    /// `userListEntry` objects (a real roster push) must still surface as
    /// `.userListReceived`.
    @Test("a TX 354 carrying userListEntry objects still emits userListReceived")
    func userList354WithEntriesEmitsRoster() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask
        let events = client.events

        try await sc.sendPush(transactionID: 354, fields: [
            PacketField(key: .userListEntry, data: encodedUser(socket: 1, icon: 2, status: 0, nickname: "alice")),
            PacketField(key: .userListEntry, data: encodedUser(socket: 2, icon: 2, status: 0, nickname: "bob"))
        ])

        var received: [User]?
        for await event in events {
            if case let .userListReceived(users) = event { received = users; break }
        }
        #expect(received?.count == 2)
        #expect(received?.first?.nickname == "alice")

        await client.disconnect()
        sc.close()
    }

    /// The HXD "User Access" variant of TX 354 (privileges field, no roster
    /// objects) must surface as `.userAccessReceived` AND be recorded on
    /// `connectionInfo.privileges` for a late subscriber.
    @Test("a privileges-only TX 354 surfaces as userAccessReceived + records on connectionInfo")
    func privilegesOnly354SurfacesUserAccess() async throws {
        let server = try await MiniHotlineServer.start()
        defer { server.stop() }

        async let serverConnTask = server.acceptHandshake()
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(name: "test", address: "127.0.0.1", port: server.port)
        )
        let sc = try await serverConnTask
        let events = client.events

        let sent: UserPrivileges = [.disconnectUsers, .canBroadcast]
        try await sc.sendPush(transactionID: 354, fields: [
            PacketField(key: .privileges, data: Data(sent.bytes))
        ])

        var received: UserPrivileges?
        for await event in events {
            if case let .userAccessReceived(privileges) = event { received = privileges; break }
        }
        #expect(received == sent)

        // Recorded for a view that starts observing after the push.
        let info = await client.connectionInfo
        #expect(info.privileges == sent)

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
