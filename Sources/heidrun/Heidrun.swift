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

        let editor = LineEditor(historyURL: Self.historyURL())
        // TAB completes client-builtin command names. Server-side
        // commands (like heidrun-server's `/topic`) and chat lines
        // don't complete — the CLI doesn't know server vocabulary,
        // and chat-line completion would clobber typing.
        editor.completion = { prefix in
            Self.builtinCommands.filter { $0.hasPrefix(prefix) }
        }

        // First connect uses no backoff — fail loudly if the host /
        // port / creds are wrong rather than silently retrying.
        FileHandle.standardError.write(Data("→ connecting to \(host):\(port)…\n".utf8))
        var session = try await establishSession(settings: settings)
        FileHandle.standardError.write(Data("→ chat ready. Type a message, or /help for commands.\n".utf8))

        defer {
            session.printerTask.cancel()
            // `disconnect()` is async; the deferred Task wrapper is the
            // canonical "fire-and-forget cleanup in a sync defer" shape.
            let dyingClient = session.client
            Task { await dyingClient.disconnect() }
        }

        REPL: while let line = editor.readLine(prompt: "> ") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // The printer task's `for await` returns when the events
            // stream ends — i.e. the TCP connection dropped. The
            // alive flag flips false then; reconnect before we'd
            // otherwise hand the dead client to `handle(input:)`.
            if !(await session.alive.isAlive()) {
                FileHandle.standardError.write(Data("→ connection lost, reconnecting…\n".utf8))
                session.printerTask.cancel()
                await session.client.disconnect()
                do {
                    session = try await reconnectWithBackoff(settings: settings)
                    FileHandle.standardError.write(Data("→ reconnected.\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("✗ reconnect failed: \(error)\n".utf8))
                    break REPL
                }
            }

            do {
                let keepGoing = try await handle(input: trimmed, client: session.client)
                if !keepGoing { break }
            } catch {
                FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
            }
        }

        FileHandle.standardError.write(Data("→ disconnected\n".utf8))
    }

    /// Holds the per-attempt state a REPL session depends on: the
    /// live `NIOHotlineClient`, the printer-task pumping its events
    /// stream to stdout, and a shared "is the connection still up"
    /// flag the printer task flips when the events stream ends.
    /// Sendable so the REPL can reassign it on reconnect.
    private struct Session: Sendable {
        let client: NIOHotlineClient
        let printerTask: Task<Void, Never>
        let alive: SessionAlive
    }

    /// Tiny actor wrapping a "connection still alive" boolean. The
    /// printer task sets it to false when the events stream ends
    /// (TCP drop, server kick, etc.); the REPL reads it before each
    /// `handle(input:)` to decide whether to reconnect first.
    private actor SessionAlive {
        private var alive = true
        func markDown() { alive = false }
        func isAlive() -> Bool { alive }
    }

    /// Connect + login + start the event-printer task. Failures
    /// (bad host / port / creds, server-side rejection) throw — the
    /// initial-connect path lets them bubble up to the user; the
    /// reconnect path catches + retries with backoff.
    private func establishSession(settings: ConnectionSettings) async throws -> Session {
        let client = try await NIOHotlineClient.connect(settings: settings)
        do {
            try await client.login(
                name: login, password: password,
                nickname: nickname, icon: icon, emoji: nil
            )
        } catch {
            await client.disconnect()
            throw error
        }
        let info = await client.connectionInfo
        FileHandle.standardError.write(Data(
            "→ connected (server v\(info.serverVersion), socket \(info.connectionSocket))\n".utf8
        ))

        let alive = SessionAlive()
        let eventStream = client.events
        let capturedNick = nickname
        let capturedIcon = icon
        let printerTask = Task {
            // Many servers gate chat behind an agreement push (TX 109).
            // Auto-accept here matches every GUI client's behaviour.
            for await event in eventStream {
                if case .agreementReceived(_, let autoAgree) = event, autoAgree {
                    try? await client.agreeToAgreement(
                        nickname: capturedNick, icon: capturedIcon, emoji: nil
                    )
                }
                printEvent(event)
            }
            // Stream ended → connection died. Flip the flag so the
            // REPL's pre-command check kicks reconnect on the next
            // line submission.
            await alive.markDown()
        }
        return Session(client: client, printerTask: printerTask, alive: alive)
    }

    /// Retry `establishSession` with capped exponential backoff. The
    /// delays (`1, 2, 4, 8, 16, 30, 30, …`) match what an
    /// auto-reconnecting IRC client would do — short enough that a
    /// flaky network recovers fast, capped so we don't hammer a
    /// down server. Caps at 8 attempts (~90s) before giving up.
    private func reconnectWithBackoff(settings: ConnectionSettings) async throws -> Session {
        let delays: [UInt64] = [1, 2, 4, 8, 16, 30, 30, 30]
        var lastError: Error?
        for (attempt, seconds) in delays.enumerated() {
            FileHandle.standardError.write(Data(
                "→ reconnect attempt \(attempt + 1)/\(delays.count) in \(seconds)s…\n".utf8
            ))
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            do {
                return try await establishSession(settings: settings)
            } catch {
                FileHandle.standardError.write(Data(
                    "✗ attempt \(attempt + 1) failed: \(error)\n".utf8
                ))
                lastError = error
            }
        }
        throw lastError ?? HotlineError.cancelled
    }

    /// Per-user shell-history file. Lives next to the user's classic
    /// dotfiles (`~/.heidrun_history`, mirroring `.bash_history` /
    /// `.zsh_history`). Returns `nil` when we can't resolve $HOME —
    /// the editor handles the nil and just skips persistence.
    private static func historyURL() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".heidrun_history")
    }

    private func parseAddress(_ server: String) -> (host: String, port: UInt16) {
        let parts = server.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        let port = parts.count == 2 ? UInt16(parts[1]) ?? 5500 : 5500
        return (host, port)
    }

    /// Process a single REPL line. Returns `false` to drop out of the
    /// loop (used by `/quit`).
    ///
    /// Dispatch rule (IRC-style):
    ///   `//foo`          → send literal `/foo` as public chat (escape hatch).
    ///   `/<known>` …     → intercepted as a CLIENT command (see switch below).
    ///   `/<other>` …     → forwarded to the SERVER as chat verbatim, so
    ///                      server-side handlers like heidrun-server's
    ///                      `/topic` get the raw line.
    ///   bare text        → public chat at Chat ID 0.
    private func handle(input: String, client: NIOHotlineClient) async throws -> Bool {
        // `//x` → "/x" as chat. Strip the leading `/`, send the rest.
        if input.hasPrefix("//") {
            try await client.sendChat(String(input.dropFirst()), in: nil, isAction: false)
            return true
        }
        guard input.hasPrefix("/") else {
            try await client.sendChat(input, in: nil, isAction: false)
            return true
        }
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
        case "ls":
            // Root by default; otherwise split a forward-slash path into
            // RemotePath components. Mirrors the syntax users already
            // know from the GUI's address bar.
            let path = parseRemotePath(argument)
            let entries = try await client.listFiles(at: path)
            printFiles(entries, atPath: path)
        case "news":
            let feed = try await client.fetchNewsFeed()
            if feed.isEmpty {
                FileHandle.standardError.write(Data("(no news posted yet)\n".utf8))
            } else {
                let body = normalizeLineEndings(feed)
                FileHandle.standardOutput.write(Data((body.hasSuffix("\n") ? body : body + "\n").utf8))
            }
        case "post":
            let trimmedPost = argument.trimmingCharacters(in: .whitespaces)
            guard !trimmedPost.isEmpty else {
                FileHandle.standardError.write(Data("usage: /post <text>\n".utf8))
                return true
            }
            try await client.postPlainNews(trimmedPost)
        case "finfo":
            // file-info shortcut: forward-slash path with the last
            // component as the filename. `/finfo foo.txt` looks up at
            // root; `/finfo Software/Mac/foo.txt` walks the path.
            let components = parseRemotePath(argument).components
            guard let name = components.last, !name.isEmpty else {
                FileHandle.standardError.write(Data("usage: /finfo <path/file>\n".utf8))
                return true
            }
            let parentPath = RemotePath(components: Array(components.dropLast()))
            let info = try await client.fetchFileInfo(at: parentPath, name: name)
            printFileInfo(info)
        case "tnews":
            // Threaded news (Hotline 1.5+). Argument optional → root.
            let path = parseRemotePath(argument)
            let bundles = try await client.fetchNewsBundles(at: path)
            printNewsBundles(bundles, atPath: path)
        case "tthreads":
            // Threads inside a category. Argument required.
            let path = parseRemotePath(argument)
            guard !path.isRoot else {
                FileHandle.standardError.write(Data("usage: /tthreads <category-path>\n".utf8))
                return true
            }
            let threads = try await client.fetchNewsThreads(at: path)
            printNewsThreads(threads, inCategory: path)
        case "tread":
            // Read one thread body. `/tread <category-path> <threadID>`.
            let pieces = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let threadID = UInt16(pieces[1].trimmingCharacters(in: .whitespaces))
            else {
                FileHandle.standardError.write(Data("usage: /tread <category-path> <threadID>\n".utf8))
                return true
            }
            let path = parseRemotePath(String(pieces[0]))
            guard !path.isRoot else {
                FileHandle.standardError.write(Data("usage: /tread <category-path> <threadID>\n".utf8))
                return true
            }
            let thread = try await client.fetchNewsThread(at: path, threadID: threadID, type: ThreadElement.plainTextType)
            printNewsThread(thread)
        case "tpost":
            // New top-level thread in a category.
            // Syntax: `/tpost <category-path> | <title> | <body>`
            // (pipe-separated because forward-slash is the path
            // delimiter and titles / bodies can contain spaces).
            let pieces = argument.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pieces.count == 3,
                  !pieces[0].isEmpty,
                  !pieces[1].isEmpty
            else {
                FileHandle.standardError.write(Data("usage: /tpost <category-path> | <title> | <body>\n".utf8))
                return true
            }
            let path = parseRemotePath(pieces[0])
            guard !path.isRoot else {
                FileHandle.standardError.write(Data("usage: /tpost <category-path> | <title> | <body>\n".utf8))
                return true
            }
            try await client.postNewsThread(
                at: path,
                parentThreadID: 0,
                title: pieces[1],
                type: ThreadElement.plainTextType,
                body: pieces[2]
            )
            FileHandle.standardError.write(Data("→ posted \"\(pieces[1])\" to /\(path.components.joined(separator: "/"))\n".utf8))
        case "treply":
            // Reply to an existing thread.
            // Syntax: `/treply <category-path> <threadID> | <body>`
            // Title is auto-set to "Re: <parent title>" (parent
            // fetched first), one Re: deep so chains don't accrete.
            let pipeSplit = argument.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pipeSplit.count == 2, !pipeSplit[1].isEmpty else {
                FileHandle.standardError.write(Data("usage: /treply <category-path> <threadID> | <body>\n".utf8))
                return true
            }
            let head = pipeSplit[0].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard head.count == 2,
                  let threadID = UInt16(head[1].trimmingCharacters(in: .whitespaces))
            else {
                FileHandle.standardError.write(Data("usage: /treply <category-path> <threadID> | <body>\n".utf8))
                return true
            }
            let path = parseRemotePath(String(head[0]))
            guard !path.isRoot else {
                FileHandle.standardError.write(Data("usage: /treply <category-path> <threadID> | <body>\n".utf8))
                return true
            }
            let parent = try await client.fetchNewsThread(
                at: path, threadID: threadID, type: ThreadElement.plainTextType
            )
            let parentTitle = parent.elements.first?.title ?? ""
            let title = replyTitle(forParent: parentTitle)
            try await client.postNewsThread(
                at: path,
                parentThreadID: threadID,
                title: title,
                type: ThreadElement.plainTextType,
                body: pipeSplit[1]
            )
            FileHandle.standardError.write(Data("→ replied to #\(threadID) in /\(path.components.joined(separator: "/"))\n".utf8))
        default:
            // Not a client builtin — forward to the server. heidrun-server
            // exposes commands like `/topic` as leading-slash chat its
            // handler interprets; this lets users reach them without the
            // CLI needing to know each one.
            try await client.sendChat(input, in: nil, isAction: false)
        }
        return true
    }

    private func printHelp() {
        let text = """
        client commands (intercepted locally):
          /who                   list users in the public room
          /info <socket>         fetch a user's profile
          /msg <socket> <text>   send a private message
          /me <action>           emote in public chat
          /nick <name>           change your nickname

          /ls [path]             list files (root by default)
          /finfo <path/file>     file metadata (size, type/creator, dates, comment)
          /news                  read the plain news feed
          /post <text>           append to the plain news feed
          /tnews [path]          threaded news: list bundles at <path>
          /tthreads <path>       threaded news: list threads in a category
          /tread <path> <id>     threaded news: show one thread body
          /tpost <path> | <title> | <body>
                                 threaded news: post a new top-level thread
          /treply <path> <id> | <body>
                                 threaded news: reply (title auto = "Re: …")

          /help                  this help
          /quit                  disconnect and exit

        anything else starting with / is sent to the server as chat,
        so server-side commands (e.g. heidrun-server's /topic) work
        without the client knowing about them.

          /topic <subject>       server-side command (forwarded as chat)
          //who                  send the literal text "/who" as chat
                                 (escape hatch when a server command name
                                 clashes with a client builtin)

        bare lines go to the public chat at Chat ID 0.

        """
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Client-builtin command names, sorted for stable TAB-completion
    /// listings. Keep this in sync with the `switch` in `handle(input:)`
    /// and the `printHelp` block — the price of a thin CLI is three
    /// places that need to agree on the verb list.
    private static let builtinCommands: [String] = [
        "exit",
        "finfo",
        "help",
        "info",
        "ls",
        "me",
        "msg",
        "news",
        "nick",
        "post",
        "pm",
        "q",
        "quit",
        "tnews",
        "tpost",
        "tread",
        "treply",
        "tthreads",
        "who"
    ]

    /// "Re: " prefix used by `/treply` to derive the reply title from
    /// the parent's title. Chains stay one `Re:` deep
    /// (case-insensitive) so `Re: Re: Re: Welcome` collapses back to
    /// `Re: Welcome` — same convention every news/mail client has
    /// used since the 80s, and matches the GUI's `NewsThreadActions.replyTitle`.
    private func replyTitle(forParent parentTitle: String) -> String {
        let prefix = "Re: "
        var trimmed = parentTitle.trimmingCharacters(in: .whitespaces)
        while trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            trimmed = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return prefix + trimmed
    }

    /// Hotline path syntax in the CLI mirrors what the GUI's address
    /// bar shows: forward-slash separated. Leading / and empty
    /// components are stripped so `/ls /Software/` works the same as
    /// `/ls Software`.
    private func parseRemotePath(_ raw: String) -> RemotePath {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return RemotePath() }
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return RemotePath(components: components)
    }

    private func printFiles(_ files: [RemoteFile], atPath path: RemotePath) {
        let location = path.isRoot ? "/" : "/" + path.components.joined(separator: "/")
        FileHandle.standardError.write(Data("→ \(files.count) item\(files.count == 1 ? "" : "s") at \(location)\n".utf8))
        if files.isEmpty { return }
        let sorted = files.sorted { lhs, rhs in
            let lhsFolder = lhs.type == .folder, rhsFolder = rhs.type == .folder
            if lhsFolder != rhsFolder { return lhsFolder }
            return lhs.name < rhs.name
        }
        let header = pad("name", 32) + "  " + pad("size", 10, alignRight: true) + "  type/creator\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        for file in sorted {
            let isFolder = file.type == .folder
            let size = isFolder
                ? "\(file.itemCount) item\(file.itemCount == 1 ? "" : "s")"
                : formatBytes(UInt64(file.size))
            let typeCreator = isFolder
                ? "—"
                : "\(file.type.stringValue)/\(file.creator.stringValue)"
            let name = isFolder ? file.name + "/" : file.name
            let line = pad(name, 32)
                + "  " + pad(size, 10, alignRight: true)
                + "  " + typeCreator + "\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private func printFileInfo(_ info: RemoteFileInfo) {
        let dateStyle = ISO8601DateFormatter()
        let created = info.creationDate.map(dateStyle.string(from:)) ?? "—"
        let modified = info.modificationDate.map(dateStyle.string(from:)) ?? "—"
        let comment = info.comment.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let text = """
        name:     \(info.file.name)
        size:     \(formatBytes(UInt64(info.file.size))) (\(info.file.size) bytes)
        type:     \(info.file.type.stringValue)
        creator:  \(info.file.creator.stringValue)
        created:  \(created)
        modified: \(modified)
        comment:  \(normalizeLineEndings(comment))

        """
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func printNewsBundles(_ bundles: [NewsBundle], atPath path: RemotePath) {
        let location = path.isRoot ? "/" : "/" + path.components.joined(separator: "/")
        FileHandle.standardError.write(Data("→ \(bundles.count) bundle\(bundles.count == 1 ? "" : "s") at \(location)\n".utf8))
        if bundles.isEmpty { return }
        let header = pad("kind", 10) + "  name\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        for bundle in bundles.sorted(by: { $0.title < $1.title }) {
            let kind = bundle.kind == .category ? "category" : "folder"
            let suffix = bundle.kind == .category ? "" : "/"
            FileHandle.standardOutput.write(Data((pad(kind, 10) + "  " + bundle.title + suffix + "\n").utf8))
        }
    }

    private func printNewsThreads(_ threads: [NewsThread], inCategory path: RemotePath) {
        let location = "/" + path.components.joined(separator: "/")
        FileHandle.standardError.write(Data("→ \(threads.count) thread\(threads.count == 1 ? "" : "s") in \(location)\n".utf8))
        if threads.isEmpty { return }
        let header = pad("id", 6, alignRight: true)
            + "  " + pad("author", 16)
            + "  " + pad("date", 10)
            + "  subject\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        let sorted = threads.sorted { $0.postDate > $1.postDate }
        for thread in sorted {
            let element = thread.elements.first
            let subject = element?.title ?? "(no subject)"
            let author = element?.author ?? "—"
            let date = thread.postDate == .distantPast ? "—" : dayFormatter.string(from: thread.postDate)
            let line = pad("\(thread.threadID)", 6, alignRight: true)
                + "  " + pad(author, 16)
                + "  " + pad(date, 10)
                + "  " + subject + "\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private func printNewsThread(_ thread: NewsThread) {
        guard let element = thread.elements.first else {
            FileHandle.standardError.write(Data("(thread has no body)\n".utf8))
            return
        }
        let dateFormatter = ISO8601DateFormatter()
        let date = thread.postDate == .distantPast ? "—" : dateFormatter.string(from: thread.postDate)
        let text = """
        title:  \(element.title)
        by:     \(element.author) on \(date)
        ---
        \(normalizeLineEndings(element.body))

        """
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// Human-readable size — KB / MB / GB powers of 1024. Bytes for
    /// anything below 1 KB.
    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        // %.1f is the formatting work; the unit gets concatenated via
        // interpolation to avoid mixing format specifiers with Swift
        // String args (a long-standing UB trap — see memory).
        let formatted = String(format: "%.1f", value)
        return formatted + units[index]
    }

    private func printUsers(_ users: [User]) {
        // Swift's String(format:) is unsafe with `%s` — it expects a C
        // string (UnsafePointer<CChar>), and a bridged Swift String
        // walks strlen into garbage. Use interpolation + padding.
        let header = pad("sock", 5, alignRight: true)
            + "  " + pad("nickname", 24)
            + "  " + "status\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        for user in users.sorted(by: { $0.nickname < $1.nickname }) {
            let line = pad("\(user.socket)", 5, alignRight: true)
                + "  " + pad(user.nickname, 24)
                + "  " + describeStatus(user.status)
                + "\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private func pad(_ value: String, _ width: Int, alignRight: Bool = false) -> String {
        if value.count >= width { return value }
        let filler = String(repeating: " ", count: width - value.count)
        return alignRight ? filler + value : value + filler
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
            FileHandle.standardOutput.write(Data("\(prefix)\(normalizeLineEndings(message))\n".utf8))
        case .messageReceived(let from, let message):
            FileHandle.standardOutput.write(Data("[pm \(from)] \(normalizeLineEndings(message))\n".utf8))
        case .userChanged(let user):
            FileHandle.standardError.write(Data("→ \(user.nickname) (\(user.socket)) updated\n".utf8))
        case .userLeft(let socket):
            FileHandle.standardError.write(Data("→ socket \(socket) left\n".utf8))
        case .broadcastReceived(let message):
            FileHandle.standardOutput.write(Data("[broadcast] \(normalizeLineEndings(message))\n".utf8))
        case .agreementReceived(let text, _):
            FileHandle.standardError.write(Data("→ server agreement:\n\(normalizeLineEndings(text))\n".utf8))
        case .newsPosted(let text):
            FileHandle.standardOutput.write(Data("[news] \(normalizeLineEndings(text))\n".utf8))
        case .disconnected(let reason):
            FileHandle.standardError.write(Data("→ disconnected (\(reason ?? "—"))\n".utf8))
        default:
            // privateChat*, userListReceived, transferQueueUpdated:
            // not surfaced in stage-1 UX. Add when we extend the CLI.
            break
        }
    }

    /// Hotline uses classic Mac `\r` as the in-message line separator.
    /// A modern terminal interprets bare `\r` as carriage-return-only,
    /// which makes multi-line server replies overwrite themselves on
    /// screen. Normalise CRLF and lone CRs to LF before we print.
    private func normalizeLineEndings(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
