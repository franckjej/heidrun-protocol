#if canImport(Network)
import Testing
import Foundation
import HeidrunCore
@testable import HeidrunNIOClient

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
}
#endif
