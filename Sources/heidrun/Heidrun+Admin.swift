import Foundation
import HeidrunCore
import HeidrunNIOClient

/// Pure, testable parsers for the admin command arguments. Each takes the
/// already-tokenized args (the REPL splits its argument string; the one-shot
/// flags arrive pre-split by ArgumentParser) and returns the parsed values or
/// a usage-error message.
enum AdminParse {
    struct Parsed<Value> {
        let value: Value?
        let error: String?
        static func ok(_ value: Value) -> Parsed { .init(value: value, error: nil) }
        static func fail(_ message: String) -> Parsed { .init(value: nil, error: message) }
    }

    /// Returns `nil` on success or an error message on unknown privilege names.
    private static func privileges(_ token: String?) -> (privs: UserPrivileges, error: String?) {
        guard let token, !token.isEmpty else { return ([], nil) }
        let parsed = PrivilegeNames.parse(token)
        if !parsed.unknown.isEmpty {
            return ([], "unknown privileges: \(parsed.unknown.joined(separator: ", "))")
        }
        return (parsed.matched, nil)
    }

    static func createUser(_ tokens: [String])
        -> Parsed<(login: String, password: String, nickname: String, privileges: UserPrivileges)> {
        guard tokens.count >= 3 else {
            return .fail("usage: newuser <login> <password> <nickname> [priv,priv,…]")
        }
        let (privs, privError) = privileges(tokens.count > 3 ? tokens[3] : nil)
        if let privError { return .fail(privError) }
        return .ok((tokens[0], tokens[1], tokens[2], privs))
    }

    static func modifyUser(_ tokens: [String])
        -> Parsed<(login: String, nickname: String, privileges: UserPrivileges, password: String?)> {
        guard tokens.count >= 2 else {
            return .fail("usage: moduser <login> <nickname> [priv,…] [password]")
        }
        let (privs, privError) = privileges(tokens.count > 2 ? tokens[2] : nil)
        if let privError { return .fail(privError) }
        let password = tokens.count > 3 ? tokens[3] : nil
        return .ok((tokens[0], tokens[1], privs, password))
    }

    static func kick(_ tokens: [String]) -> Parsed<(socket: UInt16, ban: Bool)> {
        guard let first = tokens.first, let socket = UInt16(first) else {
            return .fail("usage: kick <socket> [ban]")
        }
        let ban = tokens.count > 1 && tokens[1].lowercased() == "ban"
        return .ok((socket, ban))
    }
}

extension Heidrun {
    /// Handle an admin REPL command. Returns `true` if `command` was an admin
    /// command (handled), `false` if not (caller falls through to the normal
    /// switch / server-forward). Errors print to stderr.
    func handleAdminCommand(
        _ command: String,
        argument: String,
        client: NIOHotlineClient
    ) async throws -> Bool {
        let tokens = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        switch command {
        case "newuser", "createuser":
            let parsed = AdminParse.createUser(tokens)
            guard let user = parsed.value else { return adminUsage(parsed.error) }
            try await client.createLogin(
                name: user.login, password: user.password,
                nickname: user.nickname, privileges: user.privileges
            )
            adminOut("created login '\(user.login)'")
        case "deluser", "deleteuser":
            guard let login = tokens.first else { return adminUsage("usage: deluser <login>") }
            try await client.deleteLogin(login)
            adminOut("deleted login '\(login)'")
        case "getuser", "showuser":
            guard let login = tokens.first else { return adminUsage("usage: getuser <login>") }
            let info = try await client.openLogin(login)
            let privs = PrivilegeNames.names(in: info.privileges)
            adminOut("\(login): \(info.nickname)  [\(privs.isEmpty ? "no privileges" : privs.joined(separator: ", "))]")
        case "moduser", "modifyuser":
            let parsed = AdminParse.modifyUser(tokens)
            guard let user = parsed.value else { return adminUsage(parsed.error) }
            try await client.modifyLogin(
                name: user.login, password: user.password,
                nickname: user.nickname, privileges: user.privileges
            )
            adminOut("modified login '\(user.login)'")
        case "kick":
            let parsed = AdminParse.kick(tokens)
            guard let target = parsed.value else { return adminUsage(parsed.error) }
            try await client.kick(socket: target.socket, ban: target.ban)
            adminOut("kicked socket \(target.socket)\(target.ban ? " (banned)" : "")")
        case "broadcast":
            let message = argument.trimmingCharacters(in: .whitespaces)
            guard !message.isEmpty else { return adminUsage("usage: broadcast <message>") }
            try await client.broadcast(message)
            adminOut("broadcast sent")
        default:
            return false   // not an admin command
        }
        return true
    }

    private func adminOut(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Print a usage/error line to stderr and return `true` (command was ours, handled).
    private func adminUsage(_ message: String?) -> Bool {
        FileHandle.standardError.write(Data(((message ?? "admin error") + "\n").utf8))
        return true
    }

    /// Perform a single admin one-shot op against an already-connected client.
    /// Returns `true` if an admin one-shot flag was given (and handled); throws
    /// `OneShotError` on a usage problem so the caller exits non-zero.
    func runAdminOneShot(client: NIOHotlineClient) async throws -> Bool {
        let activeAdminFlags = [
            !createUser.isEmpty, deleteUser != nil, showUser != nil,
            !modifyUser.isEmpty, kick != nil, broadcast != nil
        ].filter { $0 }.count
        guard activeAdminFlags <= 1 else {
            throw OneShotError("use only one admin flag at a time")
        }
        if !createUser.isEmpty {
            let parsed = AdminParse.createUser(createUser)
            guard let user = parsed.value else { throw OneShotError(parsed.error ?? "bad --create-user") }
            try await client.createLogin(name: user.login, password: user.password,
                                         nickname: user.nickname, privileges: user.privileges)
            return true
        }
        if let login = deleteUser {
            try await client.deleteLogin(login); return true
        }
        if let login = showUser {
            let info = try await client.openLogin(login)
            let privs = PrivilegeNames.names(in: info.privileges)
            let privList = privs.isEmpty ? "no privileges" : privs.joined(separator: ", ")
            FileHandle.standardOutput.write(Data(
                "\(login): \(info.nickname)  [\(privList)]\n".utf8))
            return true
        }
        if !modifyUser.isEmpty {
            let parsed = AdminParse.modifyUser(modifyUser)
            guard let user = parsed.value else { throw OneShotError(parsed.error ?? "bad --modify-user") }
            // --user-password overrides the trailing-token form.
            try await client.modifyLogin(name: user.login, password: userPassword ?? user.password,
                                         nickname: user.nickname, privileges: user.privileges)
            return true
        }
        if let socket = kick {
            try await client.kick(socket: socket, ban: ban); return true
        }
        if let message = broadcast {
            try await client.broadcast(message); return true
        }
        return false
    }
}

/// Thrown by an admin one-shot usage error so `runOneShot` exits non-zero.
struct OneShotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
