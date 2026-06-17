import Testing
@testable import HeidrunCore

@Suite("PrivilegeNames")
struct PrivilegeNamesTests {
    @Test("every UserPrivileges.all bit has a name and round-trips")
    func roundTripsAll() {
        let names = PrivilegeNames.names(in: .all)
        #expect(names.count == 40)
        var rebuilt = UserPrivileges()
        for name in names { rebuilt.formUnion(PrivilegeNames.value(for: name)!) }
        #expect(rebuilt == .all)
    }

    @Test("value(for:) is case-insensitive and rejects unknown names")
    func lookup() {
        #expect(PrivilegeNames.value(for: "CreateUser") == .createUser)
        #expect(PrivilegeNames.value(for: "readchat") == .readChat)
        #expect(PrivilegeNames.value(for: "bogus") == nil)
    }

    @Test("parse splits a csv into matched bits and unknown names")
    func parseCSV() {
        let result = PrivilegeNames.parse("createUser, bogus ,deleteUser")
        #expect(result.matched == [.createUser, .deleteUser])
        #expect(result.unknown == ["bogus"])
    }
}
