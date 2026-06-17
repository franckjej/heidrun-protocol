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
