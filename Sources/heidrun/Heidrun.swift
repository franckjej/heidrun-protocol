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

    @Option(name: .long, help: "Scripting: download this remote file into the current directory, then exit (e.g. --download /files/gtest.bin).")
    var download: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Scripting: upload a local file to a remote directory, then exit. Usage: --upload <localpath> [<remotedir>].")
    var upload: [String] = []

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

        // Scripting one-shot: --download / --upload perform a single
        // transfer and exit, bypassing the interactive REPL.
        if download != nil || !upload.isEmpty {
            try await runOneShot(settings: settings)
            return
        }

        let editor = LineEditor(historyURL: Self.historyURL())
        // Live-client holder shared with the completion callback so
        // it can query the server for `/ls` path completion. Updated
        // on every reconnect below.
        let clientHolder = ClientHolder()
        // CWD lives in its own actor so the completion closure and
        // `handle(input:)` (which lives outside the REPL loop's
        // scope) can both see + mutate the same value.
        let cwdHolder = CurrentDirectoryHolder()

        // TAB completes:
        //   - the command name (first word after `/`) — static list
        //   - file-system arguments via per-command dispatch:
        //       /ls /finfo /get /download — remote files+folders
        //       /put /upload (arg 1)      — LOCAL files+folders
        //       /put /upload (arg 2)      — remote files+folders
        //       /tnews                    — news bundles
        //       /tthreads /tread /tpost /treply (first arg only,
        //         and only before any `|` — past that is freeform
        //         title/body text)        — news bundles
        //   - everything else: no-op (chat / server-forwarded
        //     commands would lead to misleading completions).
        editor.completion = { [clientHolder, cwdHolder] context in
            if context.isFirstWord {
                let matches = Self.builtinCommands.filter { $0.hasPrefix(context.currentWord) }
                return LineEditor.CompletionResult(
                    replacing: context.currentWord, candidates: matches
                )
            }
            return await Self.completeArgument(
                context: context, clientHolder: clientHolder, cwdHolder: cwdHolder
            )
        }

        // First connect uses no backoff — fail loudly if the host /
        // port / creds are wrong rather than silently retrying.
        FileHandle.standardError.write(Data("→ connecting to \(host):\(port)…\n".utf8))
        let initialSession = try await establishSession(settings: settings)
        await clientHolder.set(initialSession.client)
        FileHandle.standardError.write(Data("→ chat ready. Type a message, or /help for commands.\n".utf8))

        // Box the live session so the supervisor task can swap it on
        // reconnect while the REPL reads the current one every iteration.
        let sessionBox = SessionBox(initialSession)

        // Proactive supervisor: as soon as the printer task's events
        // stream ends (server died, ping failed, OS keepalive gave up),
        // start reconnect attempts WITHOUT waiting for the user to
        // submit a REPL line. Reads + mutates `sessionBox` to swap the
        // live client in place.
        let supervisorTask = Task { [clientHolder] in
            await Self.supervise(
                sessionBox: sessionBox,
                clientHolder: clientHolder,
                reconnect: { try await self.reconnectWithBackoff(settings: settings) }
            )
        }

        defer {
            // Cancelling the supervisor first stops it from racing the
            // REPL teardown with another reconnect attempt. Then close
            // the live client; the events-stream end unblocks any sleep
            // the supervisor was in.
            supervisorTask.cancel()
            let box = sessionBox
            Task {
                let s = await box.current()
                s.printerTask.cancel()
                await s.client.disconnect()
            }
        }

        REPL: while true {
            // Prompt advertises the current Hotline directory so the
            // user always knows what `/ls`, `/get`, etc. will operate
            // on (mirrors how a shell prompt advertises $PWD). Root
            // stays the bare "> " for compactness.
            let cwd = await cwdHolder.get()
            let prompt = cwd.isRoot ? "> " : "/\(cwd.components.joined(separator: "/")) > "
            guard let line = await editor.readLine(prompt: prompt) else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // The supervisor marks the box dead when reconnectWithBackoff
            // has exhausted all attempts. At that point there's no
            // session to hand a command to, so exit the REPL.
            if await sessionBox.isDead() {
                FileHandle.standardError.write(Data("✗ disconnected — giving up.\n".utf8))
                break REPL
            }

            let session = await sessionBox.current()

            do {
                let keepGoing = try await handle(
                    input: trimmed,
                    client: session.client,
                    cwdHolder: cwdHolder
                )
                if !keepGoing { break }
            } catch let HotlineError.serverError(id, message) {
                // Render the server's human-readable message when
                // present — heidrun-server rc7+ attaches one for the
                // "file not found" / "wrong field" failures. Falls
                // back to the bare id for older servers (and for
                // legitimate transient errors that don't include text).
                if let message {
                    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
                } else {
                    FileHandle.standardError.write(Data("✗ server error \(id)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
            }
        }

        FileHandle.standardError.write(Data("→ disconnected\n".utf8))
    }

    /// Holds the per-attempt state a REPL session depends on: the
    /// live `NIOHotlineClient` and the printer task pumping its
    /// events stream to stdout. The supervisor watches `printerTask`
    /// completion as the "connection died" signal — when the events
    /// stream finishes, the task ends. Sendable so the supervisor
    /// can hand a freshly-built session back to the box on reconnect.
    private struct Session: Sendable {
        let client: NIOHotlineClient
        let printerTask: Task<Void, Never>
    }

    /// Mutable holder for the current session. The supervisor task
    /// swaps the contents on reconnect; the REPL reads the current
    /// session at the start of each command. `isDead()` flips true
    /// only when the supervisor has exhausted reconnectWithBackoff
    /// — that's the signal for the REPL to exit.
    private actor SessionBox {
        private var session: Session
        private var dead = false

        init(_ session: Session) { self.session = session }
        func current() -> Session { session }
        func set(_ s: Session) { session = s }
        func markDead() { dead = true }
        func isDead() -> Bool { dead }
    }

    /// Background supervisor loop. Awaits the current session's
    /// printer-task completion (which happens iff the events stream
    /// ended, i.e. the connection died), then runs
    /// `reconnectWithBackoff` and swaps the new session into the box.
    /// On exhausted retries the box is marked dead so the REPL can
    /// surface a final error and exit.
    ///
    /// `reconnect` is passed as a closure rather than calling
    /// `reconnectWithBackoff` directly because this is a `static`
    /// helper — keeping it static avoids holding a strong reference
    /// to `self` from a long-lived background Task.
    private static func supervise(
        sessionBox: SessionBox,
        clientHolder: ClientHolder,
        reconnect: @Sendable @escaping () async throws -> Session
    ) async {
        while !Task.isCancelled {
            let current = await sessionBox.current()
            // `printerTask.value` returns when the for-await over the
            // events stream finishes — that's the canonical "TCP
            // session ended" signal regardless of which side closed.
            await current.printerTask.value
            if Task.isCancelled { return }

            FileHandle.standardError.write(Data("→ connection lost, reconnecting…\n".utf8))
            // Idempotent — the underlying client guards tearDown with
            // `!torn`. We disconnect anyway so any held resources
            // (NWConnection state) are released promptly.
            await current.client.disconnect()

            do {
                let newSession = try await reconnect()
                await sessionBox.set(newSession)
                await clientHolder.set(newSession.client)
                FileHandle.standardError.write(Data("→ reconnected.\n".utf8))
            } catch is CancellationError {
                return
            } catch {
                FileHandle.standardError.write(Data("✗ reconnect failed: \(error)\n".utf8))
                await sessionBox.markDead()
                return
            }
        }
    }

    /// Actor-wrapped mutable reference to the live `NIOHotlineClient`.
    /// The TAB-completion closure captures this so it can query the
    /// CURRENT client (not whatever client existed at the moment the
    /// editor was configured) — important because auto-reconnect
    /// swaps the client out under us.
    private actor ClientHolder {
        private var client: NIOHotlineClient?
        func set(_ newClient: NIOHotlineClient?) { client = newClient }
        func get() -> NIOHotlineClient? { client }
    }

    /// Actor-wrapped current directory for the session — set by
    /// `/cd`, read by the prompt loop, the path-resolving helpers
    /// (so `/ls foo` means "foo inside cwd"), and the TAB-completion
    /// closure (so completion happens relative to cwd just like the
    /// commands do). Defaults to root.
    private actor CurrentDirectoryHolder {
        private var path: RemotePath = RemotePath()
        func set(_ newPath: RemotePath) { path = newPath }
        func get() -> RemotePath { path }
    }

    /// Top-level dispatcher for `/cmd <arg…>` TAB completion.
    /// Knows the per-command argument shape — which arg index is a
    /// path, whether it's a local or remote path, whether to stop
    /// at the first `|` (for the pipe-separated post commands),
    /// and (critically) whether the command takes a SINGLE rest-of-
    /// line path argument that may contain whitespace
    /// (`/ls Heidrun Client/…`) vs. multiple space-separated args
    /// (`/put local remote`).
    ///
    /// For single-rest-of-line-path commands the replace span is
    /// the entire argument (everything after the command's first
    /// space), not just the last whitespace-delimited word — so
    /// path completion works against folders whose names contain
    /// spaces.
    private static func completeArgument(
        context: LineEditor.CompletionContext,
        clientHolder: ClientHolder,
        cwdHolder: CurrentDirectoryHolder
    ) async -> LineEditor.CompletionResult {
        guard let firstSpace = context.fullLine.firstIndex(of: " ") else {
            return .empty
        }
        let cmd = String(context.fullLine[..<firstSpace]).lowercased()
        // Whole arg string (everything after the command, possibly
        // empty if the user just typed `/ls `). Includes any
        // internal whitespace — that's the whole point of using this
        // span rather than the LineEditor's word-bounded
        // `currentWord` for single-rest-of-line-path commands.
        let argStart = context.fullLine.index(after: firstSpace)
        let restOfLine = String(context.fullLine[argStart...])
        if context.fullLine.contains("|") { return .empty }
        switch cmd {
        case "ls", "finfo", "get", "download", "cd", "rm", "mkdir":
            // Single rest-of-line path arg. Use restOfLine as the
            // replace span so paths with internal spaces work.
            guard let client = await clientHolder.get() else { return .empty }
            let cwd = await cwdHolder.get()
            let candidates = await completeRemotePath(
                word: restOfLine, client: client, cwd: cwd
            )
            return LineEditor.CompletionResult(
                replacing: restOfLine, candidates: candidates
            )
        case "put", "upload":
            // Two args, both space-separated → the conventional
            // word-bounded behaviour is what the user expects here.
            // (A v2 could add quote/escape parsing; out of scope.)
            let words = context.fullLine
                .split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            let argIndex = max(0, words.count - 2)
            if argIndex == 0 {
                let candidates = completeLocalPath(word: context.currentWord)
                return LineEditor.CompletionResult(
                    replacing: context.currentWord, candidates: candidates
                )
            }
            if argIndex == 1, let client = await clientHolder.get() {
                let cwd = await cwdHolder.get()
                let candidates = await completeRemotePath(
                    word: context.currentWord, client: client, cwd: cwd
                )
                return LineEditor.CompletionResult(
                    replacing: context.currentWord, candidates: candidates
                )
            }
            return .empty
        case "tnews":
            // Single rest-of-line news-bundle path. Always absolute
            // — news isn't reached via the file-area cwd.
            guard let client = await clientHolder.get() else { return .empty }
            let candidates = await completeNewsPath(word: restOfLine, client: client)
            return LineEditor.CompletionResult(
                replacing: restOfLine, candidates: candidates
            )
        case "tthreads", "tread", "tpost", "treply":
            // News path is the FIRST arg only — past that is a
            // threadID or pipe-separated body. Use word-bounded
            // splicing so we don't accidentally swallow a numeric
            // threadID into the path. Same caveat as /put: a path
            // containing whitespace can't be auto-completed for
            // these commands (manual typing only).
            let words = context.fullLine
                .split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            let argIndex = max(0, words.count - 2)
            guard argIndex == 0,
                  let client = await clientHolder.get() else { return .empty }
            let candidates = await completeNewsPath(
                word: context.currentWord, client: client
            )
            return LineEditor.CompletionResult(
                replacing: context.currentWord, candidates: candidates
            )
        default:
            return .empty
        }
    }

    /// Complete a remote-path word against `client.listFiles(at:)`,
    /// resolving the parent against `cwd` when the word doesn't
    /// start with `/`. The returned word preserves the user's
    /// original prefix form (relative vs absolute), so chaining
    /// TABs keeps the leading style they typed.
    ///
    /// Folders get a trailing `/` (LineEditor's "trailing slash →
    /// no auto-space" rule lets the user chain TAB to descend);
    /// files return without the slash and pick up the auto-space.
    private static func completeRemotePath(
        word: String,
        client: NIOHotlineClient,
        cwd: RemotePath
    ) async -> [String] {
        let (parentSegment, basenamePrefix) = splitPath(word)
        // Resolve the parent: if the original word started with `/`,
        // it's absolute (parent segment carries the leading `/`
        // implicitly via empty first component). Otherwise we
        // resolve relative to cwd.
        let parent = resolveRemotePath(parentSegment, against: cwd)
        guard let entries = try? await client.listFiles(at: parent) else { return [] }
        return entries
            .filter { $0.name.hasPrefix(basenamePrefix) }
            .map { entry in
                let qualified = parentSegment.isEmpty
                    ? entry.name
                    : "\(parentSegment)/\(entry.name)"
                return entry.isFolder ? "\(qualified)/" : qualified
            }
    }

    /// Complete a news-bundle path against `client.fetchNewsBundles(at:)`.
    /// Same path-splicing semantics as `completeRemotePath`: folder
    /// bundles get a trailing `/` for chained descent, leaf
    /// categories return without it so the auto-space kicks in.
    private static func completeNewsPath(
        word: String,
        client: NIOHotlineClient
    ) async -> [String] {
        let (parentSegment, basenamePrefix) = splitPath(word)
        let parentComponents = parentSegment
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let parent = RemotePath(components: parentComponents)
        guard let bundles = try? await client.fetchNewsBundles(at: parent) else { return [] }
        return bundles
            .filter { $0.title.hasPrefix(basenamePrefix) }
            .map { bundle in
                let qualified = parentSegment.isEmpty
                    ? bundle.title
                    : "\(parentSegment)/\(bundle.title)"
                // `.bundle` (folder) descends; `.category` is a leaf
                // (holds posts, no further descent useful).
                return bundle.kind == .bundle ? "\(qualified)/" : qualified
            }
    }

    /// Complete a local-filesystem path for `/put`'s first argument.
    /// Preserves the user's preferred prefix style — if they typed
    /// `~/Doc`, the returned word starts with `~/Doc…` not
    /// `/Users/…/Doc…`, so chained TABs keep the leading tilde.
    /// Folders get a trailing `/`; files don't.
    private static func completeLocalPath(word: String) -> [String] {
        let (parentSegment, basenamePrefix) = splitPath(word)
        // Empty parent ⇒ current directory; otherwise expand any
        // leading `~` to an absolute path for FileManager.
        let lookupDir: String
        if parentSegment.isEmpty {
            lookupDir = FileManager.default.currentDirectoryPath
        } else {
            lookupDir = (parentSegment as NSString).expandingTildeInPath
        }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: lookupDir) else {
            return []
        }
        return entries
            .filter { $0.hasPrefix(basenamePrefix) }
            .map { entry in
                let qualified = parentSegment.isEmpty
                    ? entry
                    : "\(parentSegment)/\(entry)"
                let absolute = (lookupDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                let exists = fileManager.fileExists(atPath: absolute, isDirectory: &isDir)
                return (exists && isDir.boolValue) ? "\(qualified)/" : qualified
            }
    }

    /// Split a `parent/parent/basename` (or bare `basename`) into
    /// `(parentSegment, basenamePrefix)`. Empty parent for bare
    /// words. Shared by all three completers so the parent-path
    /// preservation behaves the same everywhere.
    private static func splitPath(_ word: String) -> (parent: String, basename: String) {
        guard let lastSlash = word.lastIndex(of: "/") else {
            return (parent: "", basename: word)
        }
        return (
            parent: String(word[..<lastSlash]),
            basename: String(word[word.index(after: lastSlash)...])
        )
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

        // Roster on connect: show who's already here. Best-effort — some
        // servers gate the user list behind the agreement the printer
        // task auto-accepts a beat later, so a failure just yields an
        // empty list rather than aborting the session. Doubles as the
        // seed for the enter/leave tracker so existing users aren't
        // announced as fresh arrivals on the next push.
        let initialRoster = (try? await client.fetchUserList()) ?? []
        if !initialRoster.isEmpty {
            printUsers(initialRoster)
        }

        let eventStream = client.events
        let capturedNick = nickname
        let capturedIcon = icon
        let printerTask = Task {
            var knownSockets = Set(initialRoster.map(\.socket))
            // Many servers gate chat behind an agreement push (TX 109).
            // Auto-accept here matches every GUI client's behaviour.
            for await event in eventStream {
                if case .agreementReceived(_, let autoAgree) = event, autoAgree {
                    try? await client.agreeToAgreement(
                        nickname: capturedNick, icon: capturedIcon, emoji: nil
                    )
                }
                printEvent(event, knownSockets: &knownSockets)
            }
            // Stream ended → connection died. The supervisor task is
            // awaiting `printerTask.value` and will start a reconnect
            // attempt the moment this returns.
        }
        return Session(client: client, printerTask: printerTask)
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

    /// Non-interactive transfer for scripting. `--download <remote>`
    /// fetches the remote file into the current directory; `--upload
    /// <localpath> [<remotedir>]` pushes a local file to a remote
    /// directory (remote name = local basename; remote dir defaults to
    /// the server root). Connects, transfers once, and returns — the
    /// process exits 0. Failures throw, which ArgumentParser maps to a
    /// non-zero exit so shell scripts can branch on `$?`. Remote paths
    /// resolve from the server root (a leading `/` is optional).
    private func runOneShot(settings: ConnectionSettings) async throws {
        guard download == nil || upload.isEmpty else {
            throw ValidationError("Use only one of --download / --upload.")
        }
        FileHandle.standardError.write(Data("→ connecting to \(settings.address):\(settings.port)…\n".utf8))
        let session = try await establishSession(settings: settings)
        defer {
            session.printerTask.cancel()
            let liveClient = session.client
            Task { await liveClient.disconnect() }
        }
        let client = session.client

        if let remote = download {
            let components = Self.resolveRemotePath(remote, against: RemotePath()).components
            guard let name = components.last, !name.isEmpty else {
                throw ValidationError("--download expects a file path, e.g. --download /files/gtest.bin")
            }
            let parent = RemotePath(components: Array(components.dropLast()))
            let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(name)
            FileHandle.standardError.write(Data(
                "→ downloading /\(components.joined(separator: "/")) → \(local.path)\n".utf8
            ))
            try await client.downloadFile(
                at: parent, name: name, to: local,
                progress: transferProgress(verb: "↓")
            )
        } else {
            guard let localArg = upload.first else {
                throw ValidationError("--upload expects <localpath> [<remotedir>]")
            }
            let local = URL(fileURLWithPath: (localArg as NSString).expandingTildeInPath)
            guard FileManager.default.isReadableFile(atPath: local.path) else {
                throw ValidationError("local file not readable: \(local.path)")
            }
            let remoteDir = upload.count > 1
                ? Self.resolveRemotePath(upload[1], against: RemotePath())
                : RemotePath()
            let name = local.lastPathComponent
            let (type, creator) = Self.hfsCodes(for: name)
            FileHandle.standardError.write(Data(
                "→ uploading \(local.path) → /\((remoteDir.components + [name]).joined(separator: "/"))\n".utf8
            ))
            try await client.uploadFile(
                at: remoteDir, name: name, from: local,
                type: type, creator: creator,
                progress: transferProgress(verb: "↑")
            )
        }
        FileHandle.standardError.write(Data("→ done.\n".utf8))
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
    private func handle(
        input: String,
        client: NIOHotlineClient,
        cwdHolder: CurrentDirectoryHolder
    ) async throws -> Bool {
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
        // Snapshot the cwd so all path-resolution within this dispatch
        // sees the same value (a `/cd` in the middle of the same
        // command can't happen, but the snapshot keeps reads cheap).
        let cwd = await cwdHolder.get()
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
            // `/ls` with no arg lists cwd. `/ls foo` resolves
            // relative to cwd; `/ls /foo` is absolute. Same
            // semantics every shell user expects.
            let path = Self.resolveRemotePath(argument, against: cwd)
            let entries = try await client.listFiles(at: path)
            printFiles(entries, atPath: path)
        case "cd":
            // `/cd` → root. `/cd /Software` → absolute.
            // `/cd Software` → relative. `/cd ..` → up one.
            let target = Self.resolveRemotePath(argument, against: cwd)
            await cwdHolder.set(target)
            FileHandle.standardError.write(Data(
                "→ /\(target.components.joined(separator: "/"))\n".utf8
            ))
        case "pwd":
            FileHandle.standardError.write(Data(
                "/\(cwd.components.joined(separator: "/"))\n".utf8
            ))
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
            // component as the filename. `/finfo foo.txt` looks up
            // in cwd; `/finfo Software/Mac/foo.txt` walks the path
            // relative to cwd; leading `/` makes it absolute.
            let components = Self.resolveRemotePath(argument, against: cwd).components
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
        case "rm", "del", "delete":
            // Delete a file or folder. `/rm <remote-path>` — resolved
            // against the Hotline cwd unless absolute. No undo, no
            // confirmation (this is a scripting-friendly client).
            let components = Self.resolveRemotePath(argument, against: cwd).components
            guard let name = components.last, !name.isEmpty else {
                FileHandle.standardError.write(Data("usage: /rm <remote/path/entry>\n".utf8))
                return true
            }
            let parentPath = RemotePath(components: Array(components.dropLast()))
            try await client.deleteEntry(at: parentPath, name: name)
            FileHandle.standardError.write(Data("→ deleted /\(components.joined(separator: "/"))\n".utf8))
        case "mkdir":
            // Create a folder. `/mkdir <remote-path>` — the last
            // component is the new folder name; the parent must exist.
            let components = Self.resolveRemotePath(argument, against: cwd).components
            guard let name = components.last, !name.isEmpty else {
                FileHandle.standardError.write(Data("usage: /mkdir <remote/path/folder>\n".utf8))
                return true
            }
            let parentPath = RemotePath(components: Array(components.dropLast()))
            try await client.createFolder(at: parentPath, name: name)
            FileHandle.standardError.write(Data("→ created /\(components.joined(separator: "/"))\n".utf8))
        case "mv", "move":
            // Move an entry. `/mv <source-path> <dest-dir>` — the entry
            // keeps its name; dest-dir is where it lands. Source name
            // can't contain spaces (first token is the source path).
            let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                FileHandle.standardError.write(Data("usage: /mv <source/path/entry> <dest/dir>\n".utf8))
                return true
            }
            let srcComponents = Self.resolveRemotePath(String(parts[0]), against: cwd).components
            guard let name = srcComponents.last, !name.isEmpty else {
                FileHandle.standardError.write(Data("usage: /mv <source/path/entry> <dest/dir>\n".utf8))
                return true
            }
            let srcParent = RemotePath(components: Array(srcComponents.dropLast()))
            let destDir = Self.resolveRemotePath(String(parts[1]), against: cwd)
            try await client.moveEntry(from: srcParent, name: name, to: destDir)
            FileHandle.standardError.write(Data(
                "→ moved \(name) → /\((destDir.components + [name]).joined(separator: "/"))\n".utf8
            ))
        case "get", "download":
            // Download a file. `/get <remote-path>` — last path
            // component is the file name; the file is saved to the
            // CLI host's current working directory with the same
            // name. The remote path is resolved relative to the
            // Hotline cwd unless absolute (`/foo/bar`).
            let components = Self.resolveRemotePath(argument, against: cwd).components
            guard let name = components.last, !name.isEmpty else {
                FileHandle.standardError.write(Data("usage: /get <remote/path/file>\n".utf8))
                return true
            }
            let parentPath = RemotePath(components: Array(components.dropLast()))
            let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(name)
            FileHandle.standardError.write(Data("→ downloading \(name) → \(destination.path)\n".utf8))
            try await client.downloadFile(
                at: parentPath, name: name, to: destination,
                progress: transferProgress(verb: "↓")
            )
            FileHandle.standardError.write(Data("→ done.\n".utf8))
        case "put", "upload":
            // Upload a local file. `/put <local-path> [<remote-dir>]`
            // — the local file's basename becomes the remote name,
            // remote-dir defaults to the server root.
            let parts = argument.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first.map(String.init) else {
                FileHandle.standardError.write(Data("usage: /put <local-path> [<remote-dir>]\n".utf8))
                return true
            }
            let localPath = (first as NSString).expandingTildeInPath
            let source = URL(fileURLWithPath: localPath)
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                FileHandle.standardError.write(Data("✗ local file not readable: \(source.path)\n".utf8))
                return true
            }
            let remoteDir = parts.count > 1
                ? Self.resolveRemotePath(String(parts[1]), against: cwd)
                : cwd
            let name = source.lastPathComponent
            let (type, creator) = Self.hfsCodes(for: name)
            FileHandle.standardError.write(Data(
                "→ uploading \(source.path) → /\((remoteDir.components + [name]).joined(separator: "/"))\n".utf8
            ))
            try await client.uploadFile(
                at: remoteDir, name: name, from: source,
                type: type, creator: creator,
                progress: transferProgress(verb: "↑")
            )
            FileHandle.standardError.write(Data("→ done.\n".utf8))
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

          /ls [path]             list files (cwd by default)
          /cd [path]             change Hotline cwd (root by default;
                                 supports .., absolute /path, and
                                 relative path; the prompt shows cwd)
          /pwd                   print the Hotline cwd
          /finfo <path/file>     file metadata (size, type/creator, dates, comment)
          /get <path/file>       download a file to the CLI host's cwd
          /put <local-path> [<remote-dir>]
                                 upload a local file (remote-dir defaults to cwd)
          /rm <path/entry>       delete a remote file or folder
          /mkdir <path/folder>   create a remote folder
          /mv <src> <dest-dir>   move a remote file or folder
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

    /// Progress callback for HTXF transfers. Prints a single
    /// percentage line to stderr per call. The CLI doesn't try to
    /// be fancy with a redrawn progress bar — the printer task may
    /// interleave chat lines at any moment, and the REPL prompt is
    /// in raw mode, so plain "↑ 23%" lines are the least surprising
    /// shape. Throttled by the chunkSize (64KiB → ~16 calls per MB).
    private func transferProgress(verb: String) -> @Sendable (UInt64, UInt64) async -> Void {
        return { sent, total in
            guard total > 0 else { return }
            let percent = Int((Double(sent) / Double(total)) * 100)
            FileHandle.standardError.write(Data("  \(verb) \(percent)%  (\(sent)/\(total) bytes)\n".utf8))
        }
    }

    /// Pick a (type, creator) HFS 4CC pair for an outbound upload's
    /// filename. Tiny curated table — modern macOS doesn't carry
    /// these any more, so the server's `file_metadata` row gets
    /// "BINA / ????" for anything we don't recognise. Mirrors the
    /// most-common-cases subset of the GUI client's
    /// `HFSCodes.swift`. Add rows here when something real surfaces.
    private static func hfsCodes(for fileName: String) -> (HeidrunCore.FourCharCode, HeidrunCore.FourCharCode) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "text", "md", "log", "swift", "c", "h", "m", "rtf",
             "html", "htm", "csv", "json", "xml":
            return ("TEXT", "ttxt")
        case "pdf":
            return ("PDF ", "CARO")
        case "jpg", "jpeg":
            return ("JPEG", "8BIM")
        case "png":
            return ("PNGf", "8BIM")
        case "gif":
            return ("GIFf", "8BIM")
        case "tif", "tiff":
            return ("TIFF", "8BIM")
        case "mp3":
            return ("MPG3", "TVOD")
        case "m4a":
            return ("M4A ", "TVOD")
        case "mp4":
            return ("mp4 ", "TVOD")
        case "mov":
            return ("MooV", "TVOD")
        case "zip":
            return ("ZIP ", "SITx")
        case "sit", "sitx":
            return ("SITx", "SITx")
        case "dmg":
            return ("udif", "ddsk")
        case "iso":
            return ("ISO ", "ddsk")
        case "app":
            return ("APPL", "????")
        default:
            return ("BINA", "????")
        }
    }

    /// Client-builtin command names, sorted for stable TAB-completion
    /// listings. Keep this in sync with the `switch` in `handle(input:)`
    /// and the `printHelp` block — the price of a thin CLI is three
    /// places that need to agree on the verb list.
    private static let builtinCommands: [String] = [
        "cd",
        "download",
        "exit",
        "finfo",
        "get",
        "help",
        "info",
        "ls",
        "mkdir",
        "mv",
        "rm",
        "me",
        "msg",
        "news",
        "nick",
        "post",
        "put",
        "pwd",
        "pm",
        "q",
        "quit",
        "tnews",
        "tpost",
        "tread",
        "treply",
        "tthreads",
        "upload",
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
    ///
    /// Used by news commands (no cwd concept). File commands route
    /// through `resolveRemotePath(_:against:)` which adds cwd-relative
    /// resolution.
    private func parseRemotePath(_ raw: String) -> RemotePath {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return RemotePath() }
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return RemotePath(components: components)
    }

    /// Resolve a path argument against the session's Hotline cwd,
    /// shell-style:
    ///   - empty → cwd unchanged
    ///   - leading `/` → absolute (cwd ignored)
    ///   - otherwise → joined to cwd, with `..` and `.` honoured
    /// Used by every file-area command + `/cd` itself so navigation
    /// matches what every shell user expects.
    static func resolveRemotePath(_ raw: String, against cwd: RemotePath) -> RemotePath {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return cwd }
        let parts = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var components: [String] = trimmed.hasPrefix("/") ? [] : cwd.components
        for piece in parts {
            switch piece {
            case "..":
                if !components.isEmpty { components.removeLast() }
            case ".":
                break
            default:
                components.append(piece)
            }
        }
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

    /// `HH:mm:ss` clock for stamping enter/leave notifications. Static +
    /// cached: a fresh `DateFormatter` per event is wasteful and these
    /// fire from the printer task.
    private static let eventClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// `knownSockets` tracks who we've already seen so a `.userChanged`
    /// push reads as "entered" for a genuinely new socket and "updated"
    /// for an away/nick change on someone already present.
    private func printEvent(_ event: HotlineEvent, knownSockets: inout Set<UInt16>) {
        switch event {
        case .chatReceived(_, let message, let isAction):
            let prefix = isAction ? "* " : ""
            FileHandle.standardOutput.write(Data("\(prefix)\(normalizeLineEndings(message))\n".utf8))
        case .messageReceived(let from, let message):
            FileHandle.standardOutput.write(Data("[pm \(from)] \(normalizeLineEndings(message))\n".utf8))
        case .userChanged(let user):
            let stamp = Self.eventClock.string(from: Date())
            let verb = knownSockets.insert(user.socket).inserted ? "entered" : "updated"
            FileHandle.standardError.write(Data("\(stamp)  → \(user.nickname) (\(user.socket)) \(verb)\n".utf8))
        case .userLeft(let socket):
            let stamp = Self.eventClock.string(from: Date())
            knownSockets.remove(socket)
            FileHandle.standardError.write(Data("\(stamp)  → socket \(socket) left\n".utf8))
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
