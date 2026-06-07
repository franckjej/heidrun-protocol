import Foundation

/// Transport-agnostic Hotline protocol machinery: read loop, dispatch
/// switch, send-with-reply correlation, application-level keepalive, and
/// teardown. The two concrete clients (`HotlineNetworkClient` on Apple
/// platforms, `NIOHotlineClient` cross-platform) now compose one of these
/// over their own byte-pipe and forward their public ops to `send(...)`.
///
/// Previously both clients duplicated this entire stack and drifted — a
/// missing `broadcaster.finish()` in the NIO copy of `tearDown` broke the
/// CLI's auto-reconnect on Linux. With a single engine, plumbing fixes
/// land in one place.
public actor HotlineProtocolEngine {

    /// How often the keepalive task sends a `sendPing()` after `startKeepalive()`.
    /// Picked to be a little under the 60s timeout real Hotline servers used.
    public static let keepaliveInterval: Duration = .seconds(30)

    // MARK: - Stored state

    private let transport: any HotlineTransport
    private let broadcaster: EventBroadcaster
    private let packetObserver: PacketObserver?

    /// String encoding for every wire-level string field. Lives here so the
    /// engine's dispatch can decode pushes; the owning client reads it for
    /// its own outbound encoding (avoids passing it through every call).
    public nonisolated let stringEncoding: String.Encoding

    private var nextTaskNumber: UInt32 = 1
    private var pendingReplies: [UInt32: CheckedContinuation<[PacketField], Error>] = [:]
    /// Latest public/main chat topic (TX 119 with Chat ID 0). Owned here
    /// because the read loop is what sees it — clients read via the
    /// `publicChatSubject` accessor when assembling `connectionInfo`.
    private var publicChatSubject: String = ""
    /// Connected account's own access privileges from the last "User Access"
    /// push (TX 354, field 110). Read via `selfPrivilegesValue` when
    /// assembling `connectionInfo`.
    private var selfPrivileges: UserPrivileges = []
    private var readerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var torn = false

    // MARK: - Init + introspection

    public init(
        transport: any HotlineTransport,
        stringEncoding: String.Encoding,
        packetObserver: PacketObserver?
    ) {
        self.transport = transport
        self.stringEncoding = stringEncoding
        self.packetObserver = packetObserver
        self.broadcaster = EventBroadcaster()
    }

    /// Live event stream. Subscribers see every server push routed through
    /// the dispatch below; the broadcaster fans-out via per-subscriber
    /// `AsyncStream`s. `finish()`es exactly once at teardown so iterators
    /// observe end-of-stream and reconnect supervisors can react.
    public nonisolated var events: AsyncStream<HotlineEvent> {
        broadcaster.makeStream()
    }

    public var lastTaskNumber: UInt32 { nextTaskNumber &- 1 }
    public var publicChatSubjectValue: String { publicChatSubject }
    public var selfPrivilegesValue: UserPrivileges { selfPrivileges }
    public var isTorn: Bool { torn }

    // MARK: - Lifecycle

    /// Start the read loop. Call once after the client has finished its
    /// own handshake — pre-handshake bytes (the 12-byte magic + 8-byte
    /// reply) don't follow the packet framing the dispatch decodes, so
    /// they have to be drained before the engine starts owning the wire.
    public func start() {
        startReader()
    }

    /// Start the application-level keepalive ping. Call after login —
    /// pre-login pings either get ignored or treated as a protocol
    /// violation depending on the server.
    public func startKeepalive() {
        guard pingTask == nil, !torn else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: HotlineProtocolEngine.keepaliveInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                do {
                    try await self.sendPing()
                } catch {
                    await self.tearDown(with: error)
                    return
                }
            }
        }
    }

    /// Idempotent disconnect — safe to call from a supervisor's cleanup
    /// path even if the read loop already noticed the wire dying.
    public func disconnect() async {
        await tearDown(with: nil)
    }

    private func startReader() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            await self?.runReadLoop()
        }
    }

    private func stopKeepalive() {
        pingTask?.cancel()
        pingTask = nil
    }

    // MARK: - Read loop + dispatch

    private func runReadLoop() async {
        while !torn {
            do {
                let headerData = try await transport.receiveExactly(PacketHeader.byteCount)
                guard let header = PacketHeader(decoding: headerData) else {
                    throw HotlineError.malformedReply(reason: "short header")
                }
                let body: Data
                if header.dataLength > 0 {
                    body = try await transport.receiveExactly(Int(header.dataLength))
                } else {
                    body = Data()
                }
                dispatch(header: header, body: body)
            } catch {
                await tearDown(with: error)
                return
            }
        }
    }

    private func dispatch(header: PacketHeader, body: Data) {
        let fields = PacketCodec.decodeBody(body)
        // Surface every inbound packet to the developer console (when
        // an observer is attached) BEFORE reply-correlation /
        // event-broadcast so the console sees every transaction —
        // including replies, errors, and server pushes for unknown
        // transaction IDs that wouldn't be surfaced via `HotlineEvent`.
        packetObserver?.handle(.inbound, header, fields)

        // Server-pushed ping (classID=0 request carrying TX 500) needs
        // an explicit reply or the server reaps us after its keepalive
        // window. Vanilla Hotline replies with classID=1, txID=0, no
        // body. Done here BEFORE reply-correlation because pings have
        // a fresh server-allocated taskNumber that won't match any of
        // our pendingReplies.
        if header.classID == 0, header.transactionID == 500 {
            sendInbandPingReply(taskNumber: header.taskNumber)
            return
        }

        // Reply correlation: if we have a pending continuation for this
        // task number, hand it the fields (or surface the server error).
        if let continuation = pendingReplies.removeValue(forKey: header.taskNumber) {
            if header.errorID != 0 {
                let message = fields.string(.errorMessage, encoding: stringEncoding)
                let typed = HotlineError.fromWire(
                    errorID: header.errorID,
                    kind: fields.uint16(.errorKind),
                    message: message
                )
                continuation.resume(throwing: typed)
            } else {
                continuation.resume(returning: fields)
            }
            return
        }

        // Otherwise treat it as a server push.
        guard let info = InfoTransaction(rawValue: header.transactionID) else { return }
        switch info {
        case .newPost:
            if let text = fields.string(.message, encoding: stringEncoding) {
                broadcaster.yield(.newsPosted(text: text))
            }

        case .message:
            let socket = fields.uint16(.socket) ?? 0
            let text   = fields.string(.message, encoding: stringEncoding) ?? ""
            broadcaster.yield(.messageReceived(from: socket, message: text))

        case .relayChat:
            let text = fields.string(.message, encoding: stringEncoding) ?? ""
            let chat: ChatID? = fields.first(.chatReference).map { ChatID(data: $0.data) }
            let isAction = (fields.uint16(.parameter) ?? 0) != 0
            broadcaster.yield(.chatReceived(chat: chat, message: text, isAction: isAction))

        case .agreement:
            let text = fields.string(.message, encoding: stringEncoding) ?? ""
            let auto = (fields.uint16(.autoAgree) ?? 0) != 0
            broadcaster.yield(.agreementReceived(text: text, autoAgree: auto))

        case .disconnected:
            let reason = fields.string(.errorMessage, encoding: stringEncoding)
                ?? fields.string(.message, encoding: stringEncoding)
            broadcaster.yield(.disconnected(reason: reason))

        case .privateChatInvitation:
            guard let ref = fields.first(.chatReference) else { return }
            broadcaster.yield(.privateChatInvited(
                chat: ChatID(data: ref.data),
                fromUser: fields.uint16(.socket) ?? 0,
                message: fields.string(.message, encoding: stringEncoding)
            ))

        case .privateChatJoined:
            guard let ref = fields.first(.chatReference),
                  let entry = fields.first(.userListEntry),
                  let user = UserListEntryCodec.decode(entry.data, encoding: stringEncoding) else { return }
            broadcaster.yield(.privateChatJoined(chat: ChatID(data: ref.data), user: user))

        case .privateChatLeft:
            guard let ref = fields.first(.chatReference) else { return }
            broadcaster.yield(.privateChatLeft(
                chat: ChatID(data: ref.data),
                socket: fields.uint16(.socket) ?? 0
            ))

        case .privateChatChangedSubject:
            guard let ref = fields.first(.chatReference) else { return }
            let chat = ChatID(data: ref.data)
            let newSubject = fields.string(.chatSubject, encoding: stringEncoding) ?? ""
            // Record the public/main chat topic (Chat ID 0) so a UI
            // subscriber that starts observing after this push can seed
            // its header from `connectionInfo.publicChatSubject`.
            if chat.rawValue == 0 {
                publicChatSubject = newSubject
            }
            broadcaster.yield(.privateChatSubjectChanged(chat: chat, subject: newSubject))

        case .transferQueueUpdate:
            broadcaster.yield(.transferQueueUpdated)

        case .userChanged:
            let user = User(
                socket: fields.uint16(.socket) ?? 0,
                icon: fields.uint16(.icon) ?? 0,
                status: UserStatus(rawValue: fields.uint16(.status) ?? 0),
                privileges: [],
                nickname: fields.string(.nickname, encoding: stringEncoding) ?? "",
                emoji: fields.string(.userEmoji, encoding: .utf8)
            )
            broadcaster.yield(.userChanged(user: user))

        case .userLeft:
            broadcaster.yield(.userLeft(socket: fields.uint16(.socket) ?? 0))

        case .userList:
            // HXD-family servers overload TX 354: it's a full-roster push
            // when it carries `userListEntry` (300) objects, but right after
            // login they also push the connected user's access privileges on
            // the SAME transaction — an 8-byte `privileges` (110) field with
            // no user objects. Only surface a roster when entries are present;
            // a privs-only push must not decode to an empty `.userListReceived`
            // (which the VM applies as a full replacement and would wipe the
            // seeded roster).
            let entries = fields.filter { $0.key == HotlineObjectKey.userListEntry.rawValue }
            guard !entries.isEmpty else {
                // No roster objects → it's the "User Access" variant: the
                // connected user's own privileges bitmap (field 110). Record
                // it and surface it so the UI can gate admin controls. A UI
                // hint only — the server still enforces per request.
                if let privilegesField = fields.first(.privileges) {
                    let privileges = UserPrivileges(bytes: privilegesField.data)
                    selfPrivileges = privileges
                    broadcaster.yield(.userAccessReceived(privileges: privileges))
                }
                return
            }
            let users = entries.compactMap { UserListEntryCodec.decode($0.data, encoding: stringEncoding) }
            broadcaster.yield(.userListReceived(users: users))

        case .broadcast:
            let text = fields.string(.message, encoding: stringEncoding) ?? ""
            broadcaster.yield(.broadcastReceived(message: text))
        }
    }

    private func tearDown(with error: Error?) async {
        guard !torn else { return }
        torn = true
        stopKeepalive()
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
        // Fail every pending request — the continuations would otherwise
        // hang forever waiting for replies that will never arrive.
        let pending = pendingReplies
        pendingReplies.removeAll()
        for cont in pending.values {
            cont.resume(throwing: error ?? HotlineError.notConnected)
        }
        broadcaster.yield(.disconnected(reason: error.map(String.init(describing:))))
        broadcaster.finish()
    }

    // MARK: - Transaction helpers

    private func nextTaskID() -> UInt32 {
        defer { nextTaskNumber &+= 1 }
        return nextTaskNumber
    }

    /// Acknowledge a server-pushed ping (TX 500, class 0). Fire-and-
    /// forget — no need to await the bytes leaving the wire from the
    /// read-loop's perspective; if the send fails the next read will
    /// surface the error. Also surfaces the reply we just emitted to
    /// any attached `PacketObserver` so the developer console sees
    /// the conversation balanced.
    private func sendInbandPingReply(taskNumber: UInt32) {
        let replyPacket = PacketCodec.encode(
            classID: 1,
            transactionID: 0,
            taskNumber: taskNumber,
            fields: []
        )
        Task { [transport] in
            try? await transport.send(replyPacket)
        }
        if let packetObserver {
            let replyHeader = PacketHeader(
                classID: 1,
                transactionID: 0,
                taskNumber: taskNumber,
                errorID: 0,
                dataLength: UInt32(replyPacket.count),
                totalLength: UInt32(replyPacket.count)
            )
            packetObserver.handle(.outbound, replyHeader, [])
        }
    }

    /// Send a transaction. When `expectsReply` is true, suspends until
    /// the read loop correlates the response by task number and resumes
    /// the continuation; when false, resumes once the bytes are handed
    /// off to the transport.
    @discardableResult
    public func send(
        transactionID: UInt16,
        fields: [PacketField],
        expectsReply: Bool
    ) async throws -> [PacketField] {
        let taskNumber = nextTaskID()
        let packet = PacketCodec.encode(
            classID: 0,
            transactionID: transactionID,
            taskNumber: taskNumber,
            fields: fields
        )
        if let packetObserver {
            // Observer fires before the bytes leave the wire. Header
            // bookkeeping (errorID / lengths) isn't computed for the
            // outbound case because the consumer only needs direction
            // + transactionID + taskNumber + fields.
            let header = PacketHeader(
                classID: 0,
                transactionID: transactionID,
                taskNumber: taskNumber,
                errorID: 0,
                dataLength: UInt32(packet.count),
                totalLength: UInt32(packet.count)
            )
            packetObserver.handle(.outbound, header, fields)
        }
        if expectsReply {
            return try await withCheckedThrowingContinuation { cont in
                pendingReplies[taskNumber] = cont
                Task { [transport] in
                    do {
                        try await transport.send(packet)
                    } catch {
                        // Race-safe: removeValue returns nil if the read
                        // loop already drained this continuation (it
                        // can't have because the bytes haven't gone out
                        // yet, but the pattern is the same as the
                        // pre-refactor send()).
                        if let resumer = self.consumePending(taskNumber) {
                            resumer.resume(throwing: error)
                        }
                    }
                }
            }
        } else {
            try await transport.send(packet)
            return []
        }
    }

    /// Pull a pending continuation out of the table without resuming it.
    /// Used by `send`'s error path; returns `nil` if the read loop got
    /// to it first.
    fileprivate func consumePending(_ taskNumber: UInt32) -> CheckedContinuation<[PacketField], Error>? {
        pendingReplies.removeValue(forKey: taskNumber)
    }

    /// Send the protocol-defined keep-alive ping (TX 500). Mirrors the
    /// previous client-level method — exposed so the engine's own
    /// `startKeepalive` and any client that wants to emit a manual ping
    /// share one path.
    public func sendPing() async throws {
        try await send(transactionID: 500, fields: [], expectsReply: false)
    }
}
