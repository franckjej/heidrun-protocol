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
        case .outbound:
            outbound.append(transactionID)
        case .inbound:
            inbound.append(transactionID)
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

    @Test("PacketObserver.isKnown flags InfoTransaction + known requests, rejects others")
    func packetObserverIsKnown() {
        #expect(PacketObserver.isKnown(106))   // relayChat — InfoTransaction
        #expect(PacketObserver.isKnown(105))   // sendChat — known request
        #expect(PacketObserver.isKnown(107))   // login — known request, replies share the id
        #expect(PacketObserver.isKnown(500))   // sendPing — Heidrun extension
        #expect(!PacketObserver.isKnown(9999)) // dialect / unknown
        #expect(!PacketObserver.isKnown(123))  // unallocated
    }
}
#endif
