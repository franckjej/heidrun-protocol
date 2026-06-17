#if canImport(Network)
import Foundation
import Testing
import HeidrunCore
@testable import HeidrunNIOClient

@Suite("NIOHotlineClient admin")
struct NIOHotlineAdminTests {
    @Test("kick sends TX 110 with socket and ban flag")
    func kickWithBan() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let kick = try await conn.readPacket()
            #expect(kick.header.transactionID == 110)
            #expect(kick.fields.uint16(.socket) == 42)
            #expect(kick.fields.uint16(.banFlag) == 1)
            try await conn.sendReply(transactionID: 110, taskNumber: kick.header.taskNumber)
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        try await client.kick(socket: 42, ban: true)
        try await serverSide
        await client.disconnect()
    }

    @Test("kick without ban omits the ban flag")
    func kickNoBan() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let kick = try await conn.readPacket()
            #expect(kick.fields.uint16(.socket) == 7)
            #expect(kick.fields.uint16(.banFlag) == nil)
            try await conn.sendReply(transactionID: 110, taskNumber: kick.header.taskNumber)
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        try await client.kick(socket: 7, ban: false)
        try await serverSide
        await client.disconnect()
    }

    @Test("broadcast sends TX 355 with the message")
    func broadcast() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let bc = try await conn.readPacket()
            #expect(bc.header.transactionID == 355)
            #expect(bc.fields.string(.message, encoding: .macOSRoman) == "server going down")
            try await conn.sendReply(transactionID: 355, taskNumber: bc.header.taskNumber)
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        try await client.broadcast("server going down")
        try await serverSide
        await client.disconnect()
    }

    @Test("createLogin sends TX 350 with obfuscated login/password, plain nickname, privilege bytes")
    func createLogin() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let create = try await conn.readPacket()
            #expect(create.header.transactionID == 350)
            #expect(create.fields.obfuscatedString(.login, encoding: .macOSRoman) == "bob")
            #expect(create.fields.obfuscatedString(.password, encoding: .macOSRoman) == "secret")
            #expect(create.fields.string(.nickname, encoding: .macOSRoman) == "Bob")
            #expect(Array(create.fields.first(.privileges)?.data ?? Data())
                    == UserPrivileges([.readChat, .sendChat]).bytes)
            try await conn.sendReply(transactionID: 350, taskNumber: create.header.taskNumber)
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        try await client.createLogin(name: "bob", password: "secret", nickname: "Bob",
                                     privileges: [.readChat, .sendChat])
        try await serverSide
        await client.disconnect()
    }

    @Test("deleteLogin sends TX 351 with obfuscated login")
    func deleteLogin() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let del = try await conn.readPacket()
            #expect(del.header.transactionID == 351)
            #expect(del.fields.obfuscatedString(.login, encoding: .macOSRoman) == "bob")
            try await conn.sendReply(transactionID: 351, taskNumber: del.header.taskNumber)
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        try await client.deleteLogin("bob")
        try await serverSide
        await client.disconnect()
    }

    @Test("openLogin sends TX 352 with PLAIN login and parses the reply")
    func openLogin() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)
            let open = try await conn.readPacket()
            #expect(open.header.transactionID == 352)
            // login is sent PLAIN (not obfuscated) for 352:
            #expect(open.fields.string(.login, encoding: .macOSRoman) == "bob")
            try await conn.sendReply(
                transactionID: 352, taskNumber: open.header.taskNumber,
                fields: [
                    .string(.nickname, "Bob", encoding: .macOSRoman),
                    PacketField(key: .privileges, data: Data(UserPrivileges([.readChat, .postNews]).bytes))
                ])
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        let result = try await client.openLogin("bob")
        #expect(result.nickname == "Bob")
        #expect(result.privileges == [.readChat, .postNews])
        try await serverSide
        await client.disconnect()
    }

    @Test("modifyLogin: nil omits password, empty sends 0x00, non-empty obfuscates")
    func modifyLoginPasswordCases() async throws {
        let server = try await LoopbackServer.start()
        defer { server.stop() }
        async let serverSide: Void = {
            let conn = try await server.acceptHandshake()
            let loginPacket = try await conn.readPacket()
            try await conn.sendReply(transactionID: 107, taskNumber: loginPacket.header.taskNumber)

            // 1) nil password → no .password field
            let a = try await conn.readPacket()
            #expect(a.header.transactionID == 353)
            #expect(a.fields.string(.nickname, encoding: .macOSRoman) == "Bob")
            #expect(a.fields.obfuscatedString(.login, encoding: .macOSRoman) == "bob")
            #expect(a.fields.first(.password) == nil)
            #expect(Array(a.fields.first(.privileges)?.data ?? Data()) == UserPrivileges([.readChat]).bytes)
            try await conn.sendReply(transactionID: 353, taskNumber: a.header.taskNumber)

            // 2) empty password → single 0x00 byte
            let b = try await conn.readPacket()
            #expect(b.fields.first(.password)?.data == Data([0x00]))
            try await conn.sendReply(transactionID: 353, taskNumber: b.header.taskNumber)

            // 3) non-empty password → obfuscated
            let c = try await conn.readPacket()
            #expect(c.fields.obfuscatedString(.password, encoding: .macOSRoman) == "newpass")
            try await conn.sendReply(transactionID: 353, taskNumber: c.header.taskNumber)
        }()
        let client = try await NIOHotlineClient.connect(
            settings: ConnectionSettings(name: "t", address: "127.0.0.1", port: server.port))
        try await client.login(name: "admin", password: "p", nickname: "Admin", icon: 1, emoji: nil)
        try await client.modifyLogin(name: "bob", password: nil, nickname: "Bob", privileges: [.readChat])
        try await client.modifyLogin(name: "bob", password: "", nickname: "Bob", privileges: [.readChat])
        try await client.modifyLogin(name: "bob", password: "newpass", nickname: "Bob", privileges: [.readChat])
        try await serverSide
        await client.disconnect()
    }
}
#endif
