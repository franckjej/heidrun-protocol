// SPDX-License-Identifier: MIT
//
// `heidrun` — cross-platform Hotline CLI on top of NIOHotlineClient.
//
// Stage-1 scope: connect, login, REPL with `/who`, `/info`, `/msg`,
// `/me`, `/quit`. File listing, news, and transfers come in a later
// stage. The UX deliberately mirrors classic HX so muscle memory
// carries over: lines starting with `/` are commands; everything else
// is sent to the public chat at Chat ID 0.

import ArgumentParser
import Foundation
import HeidrunCore
import HeidrunNIOClient

@main
struct Heidrun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "heidrun",
        abstract: "Cross-platform Hotline client (text-only). Modern HX."
    )

    @Argument(help: "Server address — host or host:port. Port defaults to 5500.")
    var server: String

    @Option(name: [.short, .long], help: "Login name (default: guest).")
    var login: String = "guest"

    @Option(name: [.short, .long], help: "Login password. Empty for guest.")
    var password: String = ""

    @Option(name: [.short, .long], help: "Nickname shown in chat / user list.")
    var nickname: String = ProcessInfo.processInfo.environment["USER"] ?? "heidrun"

    @Option(name: .long, help: "User icon ID (Hotline classic icon set). Default 25.")
    var icon: UInt16 = 25

    func run() async throws {
        let (host, port) = parseAddress(server)
        let settings = ConnectionSettings(
            name: "heidrun",
            address: host,
            port: port,
            nickname: nickname,
            login: login,
            icon: icon,
            useTLS: false
        )
        FileHandle.standardError.write(Data("→ connecting to \(host):\(port)…\n".utf8))
        let client = try await NIOHotlineClient.connect(settings: settings)
        do {
            let emojiArg: String? = nil
            try await client.login(name: login, password: password, nickname: nickname, icon: icon, emoji: emojiArg)
        } catch {
            await client.disconnect()
            throw error
        }
        let info = await client.connectionInfo
        FileHandle.standardError.write(Data("→ connected (server v\(info.serverVersion), socket \(info.connectionSocket))\n".utf8))

        // Spin up the inbound-event printer in a child task; it prints
        // chat / PMs / join-leave to stdout while the main task reads
        // user commands on stdin. The two streams will interleave on a
        // shared TTY — acceptable for MVP, fixable later with readline.
        let eventStream = client.events
        let printerTask = Task {
            for await event in eventStream {
                printEvent(event)
            }
        }

        // Read stdin line-by-line. `readLine` is blocking but Task
        // isolation keeps it off the NIO event loop. EOF (Ctrl-D)
        // gracefully drops out of the loop and disconnects.
        FileHandle.standardError.write(Data("→ chat ready. Type a message, or /help for commands.\n".utf8))
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do {
                let keepGoing = try await handle(input: trimmed, client: client)
                if !keepGoing { break }
            } catch {
                FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
            }
        }

        printerTask.cancel()
        await client.disconnect()
        FileHandle.standardError.write(Data("→ disconnected\n".utf8))
    }

    private func parseAddress(_ server: String) -> (host: String, port: UInt16) {
        let parts = server.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        let port = parts.count == 2 ? UInt16(parts[1]) ?? 5500 : 5500
        return (host, port)
    }

    /// Process a single REPL line. Returns `false` to drop out of the
    /// loop (used by `/quit`). Bare text → public chat at Chat ID 0.
    private func handle(input: String, client: NIOHotlineClient) async throws -> Bool {
        if input.hasPrefix("/") {
            let parts = input.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let command = parts.first.map(String.init)?.lowercased() ?? ""
            let argument = parts.count > 1 ? String(parts[1]) : ""
            switch command {
            case "quit", "exit", "q":
                return false
            case "help", "?":
                printHelp()
            case "who":
                let users = try await client.fetchUserList()
                printUsers(users)
            case "info":
                guard let socket = UInt16(argument.trimmingCharacters(in: .whitespaces)) else {
                    FileHandle.standardError.write(Data("usage: /info <socket>\n".utf8))
                    return true
                }
                let info = try await client.fetchUserInfo(socket: socket)
                printUserInfo(info)
            case "msg", "pm":
                let pieces = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2,
                      let socket = UInt16(pieces[0])
                else {
                    FileHandle.standardError.write(Data("usage: /msg <socket> <text>\n".utf8))
                    return true
                }
                try await client.sendPrivateMessage(String(pieces[1]), to: socket)
            case "me":
                try await client.sendChat(argument, in: nil, isAction: true)
            case "nick":
                let trimmedNick = argument.trimmingCharacters(in: .whitespaces)
                guard !trimmedNick.isEmpty else {
                    FileHandle.standardError.write(Data("usage: /nick <new-name>\n".utf8))
                    return true
                }
                try await client.changeNickname(trimmedNick, icon: icon, emoji: nil)
            default:
                FileHandle.standardError.write(Data("unknown command: /\(command). Try /help.\n".utf8))
            }
        } else {
            try await client.sendChat(input, in: nil, isAction: false)
        }
        return true
    }

    private func printHelp() {
        let text = """
        commands:
          /who                   list users in the public room
          /info <socket>         fetch a user's profile (use the socket from /who)
          /msg <socket> <text>   send a private message
          /me <action>           emote in public chat
          /nick <name>           change your nickname
          /help                  this help
          /quit                  disconnect and exit
        anything else is sent to the public chat.

        """
        FileHandle.standardError.write(Data(text.utf8))
    }

    private func printUsers(_ users: [User]) {
        let header = String(format: "%5s  %-24s  %s\n", "sock", "nickname", "status")
        FileHandle.standardOutput.write(Data(header.utf8))
        for user in users.sorted(by: { $0.nickname < $1.nickname }) {
            let line = String(format: "%5d  %-24s  %s\n",
                              user.socket,
                              user.nickname,
                              describeStatus(user.status))
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private func describeStatus(_ status: UserStatus) -> String {
        var bits: [String] = []
        if status.flags.contains(.away)          { bits.append("away") }
        if status.flags.contains(.admin)         { bits.append("admin") }
        if status.flags.contains(.sysOp)         { bits.append("sysop") }
        if status.flags.contains(.inPrivateChat) { bits.append("in-pchat") }
        if status.flags.contains(.hasPrivateMsg) { bits.append("has-pm") }
        return bits.isEmpty ? "—" : bits.joined(separator: ",")
    }

    private func printUserInfo(_ info: UserInfo) {
        let text = """
        nickname:      \(info.user.nickname)
        socket:        \(info.user.socket)
        icon:          \(info.user.icon)
        account login: \(info.accountLogin.isEmpty ? "—" : info.accountLogin)
        info:
        \(info.infoText.isEmpty ? "(empty)" : info.infoText)

        """
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func printEvent(_ event: HotlineEvent) {
        switch event {
        case .chatReceived(_, let message, let isAction):
            let prefix = isAction ? "* " : ""
            FileHandle.standardOutput.write(Data("\(prefix)\(message)\n".utf8))
        case .messageReceived(let from, let message):
            FileHandle.standardOutput.write(Data("[pm \(from)] \(message)\n".utf8))
        case .userChanged(let user):
            FileHandle.standardError.write(Data("→ \(user.nickname) (\(user.socket)) updated\n".utf8))
        case .userLeft(let socket):
            FileHandle.standardError.write(Data("→ socket \(socket) left\n".utf8))
        case .broadcastReceived(let message):
            FileHandle.standardOutput.write(Data("[broadcast] \(message)\n".utf8))
        case .agreementReceived(let text, _):
            FileHandle.standardError.write(Data("→ server agreement:\n\(text)\n".utf8))
        case .disconnected(let reason):
            FileHandle.standardError.write(Data("→ disconnected (\(reason ?? "—"))\n".utf8))
        default:
            // newsPosted, privateChat*, userListReceived, transferQueueUpdated:
            // not surfaced in stage-1 UX. Add when we extend the CLI.
            break
        }
    }
}
