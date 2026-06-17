import Testing
import HeidrunCore
@testable import heidrun

@Suite("AdminParse")
struct AdminParseTests {
    @Test("createUser parses login/password/nickname + optional privileges")
    func createUser() throws {
        let created = try #require(AdminParse.createUser(["bob", "secret", "Bob", "readChat,sendChat"]).value)
        #expect(created.login == "bob")
        #expect(created.password == "secret")
        #expect(created.nickname == "Bob")
        #expect(created.privileges == [.readChat, .sendChat])

        let noPriv = try #require(AdminParse.createUser(["bob", "secret", "Bob"]).value)
        #expect(noPriv.privileges == [])

        #expect(AdminParse.createUser(["bob"]).value == nil)
        #expect(AdminParse.createUser(["bob", "p", "Bob", "bogus"]).value == nil)
    }

    @Test("modifyUser: privileges + optional trailing password")
    func modifyUser() throws {
        let withPass = try #require(AdminParse.modifyUser(["bob", "Bob", "readChat", "newpass"]).value)
        #expect(withPass.password == "newpass")
        #expect(withPass.privileges == [.readChat])

        let noPass = try #require(AdminParse.modifyUser(["bob", "Bob", "readChat"]).value)
        #expect(noPass.password == nil)
    }

    @Test("kick: socket + optional ban")
    func kick() throws {
        let banned = try #require(AdminParse.kick(["5", "ban"]).value)
        #expect(banned.socket == 5)
        #expect(banned.ban == true)
        let plain = try #require(AdminParse.kick(["7"]).value)
        #expect(plain.ban == false)
        #expect(AdminParse.kick(["notanumber"]).value == nil)
    }
}
