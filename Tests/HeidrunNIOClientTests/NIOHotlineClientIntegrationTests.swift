#if canImport(Network)
import Testing
import Foundation
import HeidrunCore
@testable import HeidrunNIOClient

/// Accumulator the PacketObserver test pushes into. An actor so the
/// observer's @Sendable handler can write across threads safely.
private actor ObservedPackets {
    private(set) var outbound: [UInt16] = []
    private(set) var inbound: [UInt16] = []

    func record(direction: PacketObserver.Direction, transactionID: UInt16, fields: [PacketField]) {
        switch direction {
        case .outbound: outbound.append(transactionID)
        case .inbound:  inbound.append(transactionID)
        }
    }
}

/// Cross-stack: the NIO client talks to the NWListener-based LoopbackServer,
/// proving the wire protocol.
@Suite("NIOHotlineClient + loopback")
struct NIOHotlineClientIntegrationTests {
    @Test("connects, logs in, and sends a chat the server receives")
    func loginAndChat() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }

        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            #expect(loginPacket.header.transactionID == 107)
            // Option 2: the nickname rides IN the login packet, UTF-8-encoded
            // (the client always advertises textEncoding). "Spirit" is ASCII.
            #expect(loginPacket.fields.string(.nickname, encoding: .utf8) == "Spirit")
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let chatPacket = try await conn.readPacket()
            #expect(chatPacket.header.transactionID == 105)
            #expect(chatPacket.fields.string(.message) == "hello from NIO")
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Spirit", icon: 1, emoji: nil)
        try await client.sendChat("hello from NIO", in: nil, isAction: false)
        try await serverSide
        await client.disconnect()
    }

    /// Option 2: the NIO client always advertises CAPABILITY_TEXT_ENCODING, so
    /// the nickname rides IN the login(107) packet UTF-8-encoded — no post-login
    /// TX 304. A non-ASCII nick must arrive as UTF-8 bytes in the login packet.
    @Test("login packet carries the nickname UTF-8-encoded")
    func loginNickIsUTF8InLoginPacket() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let accentedNick = "café"

        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            let advertised = loginPacket.fields.uint16(.capabilities) ?? 0
            #expect(advertised & CapabilityFlags.textEncoding.rawValue != 0)
            #expect(loginPacket.fields.string(.nickname, encoding: .utf8) == accentedNick)
            #expect(loginPacket.fields.first(.nickname)?.data == accentedNick.data(using: .utf8))
            try await conn.sendReply(
                transactionID: 107,
                taskNumber: loginPacket.header.taskNumber,
                fields: [.uint16(.capabilities, CapabilityFlags.textEncoding.rawValue)]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: accentedNick, icon: 1, emoji: nil)
        try await serverSide
        await client.disconnect()
    }

    @Test("login advertises capabilities and enables large files when echoed")
    func largeFilesNegotiatedOn() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            #expect(loginPacket.fields.uint16(.capabilities) == CapabilityFlags.supported.rawValue)
            // Nickname rides in the login packet, UTF-8-encoded.
            #expect(loginPacket.fields.string(.nickname, encoding: .utf8) == "Spirit")
            try await conn.sendReply(
                transactionID: 107,
                taskNumber: loginPacket.header.taskNumber,
                fields: [.uint16(.capabilities, CapabilityFlags.largeFiles.rawValue)]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Spirit", icon: 1, emoji: nil)
        try await serverSide
        let enabled = await client.largeFilesEnabled
        #expect(enabled)
        await client.disconnect()
    }

    @Test("large files stays off when the server omits the capability echo")
    func largeFilesNegotiatedOff() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Spirit", icon: 1, emoji: nil)
        try await serverSide
        let enabled = await client.largeFilesEnabled
        #expect(!enabled)
        await client.disconnect()
    }

    @Test("emits chatReceived for a server-pushed relayChat")
    func receivesChat() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            try await conn.sendPush(transactionID: 106, fields: [   // 106 = relayChat
                .string(.message, " Bob: hi there", encoding: .macOSRoman)
            ])
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        let events = client.events
        try await client.login(name: "j", password: "p", nickname: "Spirit", icon: 1, emoji: nil)
        try await serverSide

        var received: String?
        for await event in events {
            if case let .chatReceived(_, message, _) = event { received = message; break }
        }
        #expect(received == " Bob: hi there")
        await client.disconnect()
    }

    @Test("fetchUserInfo sends TX 303 with the socket and decodes the reply")
    func fetchUserInfoRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let infoPacket = try await conn.readPacket()
            #expect(infoPacket.header.transactionID == 303)
            #expect(infoPacket.fields.uint16(.socket) == 42)
            try await conn.sendReply(
                transactionID: 303,
                taskNumber: infoPacket.header.taskNumber,
                fields: [
                    .uint16(.icon, 7),
                    .uint16(.status, 0),
                    .string(.nickname, "Bob", encoding: .macOSRoman),
                    .string(.message, "infos for bob", encoding: .macOSRoman),
                    .string(.login, "bob", encoding: .macOSRoman)
                ]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let info = try await client.fetchUserInfo(socket: 42)
        #expect(info.user.socket == 42)
        #expect(info.user.icon == 7)
        #expect(info.user.nickname == "Bob")
        #expect(info.infoText == "infos for bob")
        #expect(info.accountLogin == "bob")
        try await serverSide
        await client.disconnect()
    }

    @Test("sendPrivateMessage sends TX 108 with .socket + .message")
    func sendPrivateMessageRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let pmPacket = try await conn.readPacket()
            #expect(pmPacket.header.transactionID == 108)
            #expect(pmPacket.fields.uint16(.socket) == 42)
            #expect(pmPacket.fields.string(.message) == "hi there")
            try await conn.sendReply(transactionID: 108, taskNumber: pmPacket.header.taskNumber)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.sendPrivateMessage("hi there", to: 42)
        try await serverSide
        await client.disconnect()
    }

    @Test("agreeToAgreement sends TX 121 with .nickname + .icon (no reply expected)")
    func agreeToAgreementSendsTX121() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let agreePacket = try await conn.readPacket()
            #expect(agreePacket.header.transactionID == 121)
            #expect(agreePacket.fields.string(.nickname) == "Tester")
            #expect(agreePacket.fields.uint16(.icon) == 7)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.agreeToAgreement(nickname: "Tester", icon: 7, emoji: nil)
        try await serverSide
        await client.disconnect()
    }

    @Test("listFiles sends TX 200 with the path and decodes the file-list entries")
    func listFilesRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let lsPacket = try await conn.readPacket()
            #expect(lsPacket.header.transactionID == 200)
            // RemotePath is encoded as a single .filePath blob — easiest
            // check is that the field is present (encoding round-trip is
            // covered by RemotePathCodec's own tests).
            #expect(lsPacket.fields.first(.filePath) != nil)
            let folder = RemoteFile(name: "Software", type: .folder, creator: FourCharCode(rawValue: 0), size: 0, itemCount: 4)
            let textFile = RemoteFile(name: "notes.txt", type: "TEXT", creator: "ttxt", size: 1234, itemCount: 0)
            try await conn.sendReply(
                transactionID: 200,
                taskNumber: lsPacket.header.taskNumber,
                fields: [
                    FileListEntryCodec.encode(folder, encoding: .macOSRoman),
                    FileListEntryCodec.encode(textFile, encoding: .macOSRoman)
                ]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let entries = try await client.listFiles(at: RemotePath())
        #expect(entries.count == 2)
        #expect(entries.contains { $0.name == "Software" && $0.type == .folder && $0.itemCount == 4 })
        #expect(entries.contains { $0.name == "notes.txt" && $0.type.stringValue == "TEXT" && $0.creator.stringValue == "ttxt" })
        try await serverSide
        await client.disconnect()
    }

    @Test("fetchFileInfo sends TX 206 and decodes type / creator / size / comment")
    func fetchFileInfoRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let infoPacket = try await conn.readPacket()
            #expect(infoPacket.header.transactionID == 206)
            #expect(infoPacket.fields.string(.fileName) == "image.jpg")
            try await conn.sendReply(
                transactionID: 206,
                taskNumber: infoPacket.header.taskNumber,
                fields: [
                    .string(.fileName, "image.jpg", encoding: .macOSRoman),
                    PacketField(key: .longFileType, data: Data([0x4A, 0x50, 0x45, 0x47])),     // JPEG
                    PacketField(key: .longFileCreator, data: Data([0x38, 0x42, 0x49, 0x4D])),  // 8BIM
                    .uint32(.fileSize, 2048),
                    .string(.fileComment, "snapshot from Mac OS 9", encoding: .macOSRoman)
                ]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let info = try await client.fetchFileInfo(at: RemotePath(), name: "image.jpg")
        #expect(info.file.name == "image.jpg")
        #expect(info.file.type.stringValue == "JPEG")
        #expect(info.file.creator.stringValue == "8BIM")
        #expect(info.file.size == 2048)
        #expect(info.comment == "snapshot from Mac OS 9")
        try await serverSide
        await client.disconnect()
    }

    @Test("fetchNewsFeed sends TX 101 and returns the .message body")
    func fetchNewsFeedRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let newsPacket = try await conn.readPacket()
            #expect(newsPacket.header.transactionID == 101)
            try await conn.sendReply(
                transactionID: 101,
                taskNumber: newsPacket.header.taskNumber,
                fields: [.string(.message, "first post\rsecond post", encoding: .macOSRoman)]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let feed = try await client.fetchNewsFeed()
        #expect(feed == "first post\rsecond post")
        try await serverSide
        await client.disconnect()
    }

    @Test("postPlainNews sends TX 103 with the .message field")
    func postPlainNewsRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let postPacket = try await conn.readPacket()
            #expect(postPacket.header.transactionID == 103)
            #expect(postPacket.fields.string(.message) == "stage-1 lives")
            try await conn.sendReply(transactionID: 103, taskNumber: postPacket.header.taskNumber)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.postPlainNews("stage-1 lives")
        try await serverSide
        await client.disconnect()
    }

    @Test("deleteEntry sends TX 204 with the name + path")
    func deleteEntryRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let delPacket = try await conn.readPacket()
            #expect(delPacket.header.transactionID == 204)
            #expect(delPacket.fields.string(.fileName) == "junk.txt")
            #expect(delPacket.fields.first(.filePath) != nil)
            try await conn.sendReply(transactionID: 204, taskNumber: delPacket.header.taskNumber)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.deleteEntry(at: RemotePath(components: ["Software"]), name: "junk.txt")
        try await serverSide
        await client.disconnect()
    }

    @Test("createFolder sends TX 205 with the name + path")
    func createFolderRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let mkPacket = try await conn.readPacket()
            #expect(mkPacket.header.transactionID == 205)
            #expect(mkPacket.fields.string(.fileName) == "New Folder")
            #expect(mkPacket.fields.first(.filePath) != nil)
            try await conn.sendReply(transactionID: 205, taskNumber: mkPacket.header.taskNumber)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.createFolder(at: RemotePath(components: ["Software"]), name: "New Folder")
        try await serverSide
        await client.disconnect()
    }

    @Test("moveEntry sends TX 208 with name + source path + destination path")
    func moveEntryRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let mvPacket = try await conn.readPacket()
            #expect(mvPacket.header.transactionID == 208)
            #expect(mvPacket.fields.string(.fileName) == "report.pdf")
            #expect(mvPacket.fields.first(.filePath) != nil)
            #expect(mvPacket.fields.first(.destinationPath) != nil)
            try await conn.sendReply(transactionID: 208, taskNumber: mvPacket.header.taskNumber)
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.moveEntry(
            from: RemotePath(components: ["Inbox"]),
            name: "report.pdf",
            to: RemotePath(components: ["Archive", "2026"])
        )
        try await serverSide
        await client.disconnect()
    }

    @Test("fetchNewsBundles sends TX 370 with newsPath and decodes the entries")
    func fetchNewsBundlesRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let bundlesPacket = try await conn.readPacket()
            #expect(bundlesPacket.header.transactionID == 370)
            #expect(bundlesPacket.fields.first(.newsPath) != nil)
            try await conn.sendReply(
                transactionID: 370,
                taskNumber: bundlesPacket.header.taskNumber,
                fields: [
                    NewsBundleEntryCodec.encode(name: "Software", kind: .bundle, itemCount: 5),
                    NewsBundleEntryCodec.encode(name: "Announcements", kind: .category, itemCount: 12)
                ]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let bundles = try await client.fetchNewsBundles(at: RemotePath())
        #expect(bundles.count == 2)
        #expect(bundles.contains { $0.title == "Software" && $0.kind == .bundle })
        #expect(bundles.contains { $0.title == "Announcements" && $0.kind == .category })
        try await serverSide
        await client.disconnect()
    }

    @Test("fetchNewsThreads sends TX 371 and decodes the newsThreadList blob")
    func fetchNewsThreadsRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        let posted = Date(timeIntervalSince1970: 1_716_900_000)
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let threadsPacket = try await conn.readPacket()
            #expect(threadsPacket.header.transactionID == 371)
            let entries = [
                NewsThreadListEntry(threadID: 1, parentID: 0, postedAt: posted, title: "Hello world", author: "alice", body: "first post"),
                NewsThreadListEntry(threadID: 2, parentID: 1, postedAt: posted, title: "Re: Hello world", author: "bob", body: "reply")
            ]
            try await conn.sendReply(
                transactionID: 371,
                taskNumber: threadsPacket.header.taskNumber,
                fields: [NewsThreadListCodec.encode(entries, encoding: .macOSRoman)]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let threads = try await client.fetchNewsThreads(at: RemotePath(components: ["Announcements"]))
        #expect(threads.count == 2)
        #expect(threads.contains { $0.threadID == 1 && $0.elements.first?.title == "Hello world" && $0.elements.first?.author == "alice" })
        #expect(threads.contains { $0.threadID == 2 && $0.parentID == 1 && $0.elements.first?.author == "bob" })
        try await serverSide
        await client.disconnect()
    }

    @Test("PacketObserver fires once per outbound encode and once per inbound decode")
    func packetObserverHook() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            // Server-pushed broadcast — inbound, no matching reply.
            try await conn.sendPush(transactionID: 355, fields: [
                .string(.message, "hello", encoding: .macOSRoman)
            ])
            let chatPacket = try await conn.readPacket()
            #expect(chatPacket.header.transactionID == 105)
        }()

        let observed = ObservedPackets()
        let observer = PacketObserver { direction, header, fields in
            Task { await observed.record(direction: direction, transactionID: header.transactionID, fields: fields) }
        }
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port),
            packetObserver: observer
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await client.sendChat("ping", in: nil, isAction: false)
        try await serverSide

        // Give the observer's async record task a moment to drain.
        try await Task.sleep(for: .milliseconds(50))

        let outbound = await observed.outbound
        let inbound = await observed.inbound
        #expect(outbound.contains(107), "outbound observer never saw the login TX")
        #expect(outbound.contains(105), "outbound observer never saw the sendChat TX")
        #expect(inbound.contains(107), "inbound observer never saw the login reply")
        #expect(inbound.contains(355), "inbound observer never saw the server's broadcast push")
        await client.disconnect()
    }

    @Test("server-pushed TX 500 ping is answered with a class-1 reply on the same task number")
    func inboundPingIsAnswered() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            // Server-class ping with a non-zero task number so we can
            // assert the client echoes it back on its reply.
            try await conn.sendPush(transactionID: 500, taskNumber: 4242)
            let reply = try await conn.readPacket()
            #expect(reply.header.classID == 1, "ping reply should be class 1 (reply)")
            #expect(reply.header.taskNumber == 4242, "ping reply must echo the server's task number")
            #expect(reply.fields.isEmpty, "ping reply carries no body fields")
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        try await serverSide
        await client.disconnect()
    }

    @Test("PacketObserver.isKnown flags InfoTransaction + known requests, rejects others")
    func packetObserverIsKnown() {
        #expect(PacketObserver.isKnown(106))   // relayChat — InfoTransaction
        #expect(PacketObserver.isKnown(105))   // sendChat — known request
        #expect(PacketObserver.isKnown(107))   // login — known request, replies share the id
        #expect(PacketObserver.isKnown(500))   // sendPing — Heidrun extension
        #expect(!PacketObserver.isKnown(9999)) // dialect / unknown
        #expect(!PacketObserver.isKnown(123))  // unallocated
    }

    @Test("fetchNewsThread sends TX 400 and decodes the body element")
    func fetchNewsThreadRoundTrip() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let threadPacket = try await conn.readPacket()
            #expect(threadPacket.header.transactionID == 400)
            #expect(threadPacket.fields.uint16(.newsArticleID) == 7)
            try await conn.sendReply(
                transactionID: 400,
                taskNumber: threadPacket.header.taskNumber,
                fields: [
                    .uint16(.newsParentThread, 0),
                    .string(.newsTitle, "Hello world", encoding: .macOSRoman),
                    .string(.newsAuthor, "alice", encoding: .macOSRoman),
                    .string(.newsType, ThreadElement.plainTextType, encoding: .macOSRoman),
                    .string(.newsData, "the body text", encoding: .macOSRoman)
                ]
            )
        }()

        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port)
        )
        try await client.login(name: "j", password: "p", nickname: "Tester", icon: 1, emoji: nil)
        let thread = try await client.fetchNewsThread(
            at: RemotePath(components: ["Announcements"]),
            threadID: 7,
            type: ThreadElement.plainTextType
        )
        #expect(thread.threadID == 7)
        #expect(thread.elements.first?.title == "Hello world")
        #expect(thread.elements.first?.author == "alice")
        #expect(thread.elements.first?.body == "the body text")
        try await serverSide
        await client.disconnect()
    }
}
#endif
