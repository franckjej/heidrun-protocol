import Foundation
import Network
import HeidrunCore

/// One client connection's lifetime.
///
/// Owns the `NWConnection`, runs the handshake + read loop, and
/// dispatches each transaction to the appropriate handler. All shared
/// state lives in `ServerState`.
final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let state: ServerState
    private let queue: DispatchQueue
    private var socketID: UInt16 = 0
    private var nickname: String = ""
    private var icon: UInt16 = 1
    private let encoding: String.Encoding = .macOSRoman
    /// Last time we observed any inbound activity from the peer
    /// (handshake byte, transaction packet, ping). Used as a liveness
    /// signal by the idle-timeout watcher.
    private var lastInboundAt: ContinuousClock.Instant = .now

    /// How long the connection can sit silent before the idle watcher
    /// kills it. The client's keepalive ping fires every 30s, so 90s
    /// gives three windows of grace before we declare the link dead.
    private static let idleTimeout: Duration = .seconds(90)

    init(connection: NWConnection, state: ServerState, queue: DispatchQueue) {
        self.connection = connection
        self.state = state
        self.queue = queue
    }

    func run() async {
        let idleWatcher = startIdleWatcher()
        defer { idleWatcher.cancel() }

        do {
            try await connection.startAndWaitForReady(on: queue)
            try await handshake()
            try await readLoop()
        } catch {
            print("[conn \(socketID)] closed: \(error)")
        }
        if socketID != 0 {
            // Drop our own push sink BEFORE we broadcast 302 / 118 so
            // `state.broadcast` doesn't try to send to our half-closed
            // NWConnection. A cancelled NWConnection's send completion
            // can take a long time (or never fire), which would stall
            // the for-await loop and starve every other client of the
            // departure notification.
            await state.unregister(socket: socketID)
            await announceUserLeft(socket: socketID)
            await evictFromPrivateChats()
        } else {
            await state.unregister(socket: socketID)
        }
        connection.cancel()
    }

    /// On disconnect: drop this socket from every private chat it was
    /// in and notify the remaining members so their participant lists
    /// stay accurate. Mirrors a real Hotline server's behaviour when a
    /// user drops mid-conversation.
    private func evictFromPrivateChats() async {
        let evictions = await state.evictFromAllPrivateChats(socket: socketID)
        for (chatID, remaining) in evictions {
            let push = PacketCodec.encode(
                classID: 0,
                transactionID: 118,
                taskNumber: 0,
                fields: [
                    PacketField(key: .chatReference, data: ChatID(rawValue: chatID).data),
                    PacketField.uint16(.socket, socketID)
                ]
            )
            await state.push(to: remaining, packet: push)
        }
    }

    // MARK: - Handshake

    private func handshake() async throws {
        // Client sends "TRTPHOTL\0\1\0\2" (12 bytes); we reply "TRTP" + UInt32(0).
        let magic = try await connection.receiveExactly(12)
        guard magic.prefix(8) == Data([
            0x54, 0x52, 0x54, 0x50,  // TRTP
            0x48, 0x4F, 0x54, 0x4C   // HOTL
        ]) else {
            throw NSError(domain: "TestServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "bad client magic"
            ])
        }
        try await connection.sendAsync(Data([
            0x54, 0x52, 0x54, 0x50,  // TRTP
            0x00, 0x00, 0x00, 0x00   // error = 0
        ]))
    }

    /// Background watcher that closes the NWConnection once `lastInboundAt`
    /// drifts past `idleTimeout` ago. Cancelling the connection unblocks
    /// the read loop with `.notConnected`, which feeds the normal cleanup
    /// path in `run()`.
    private func startIdleWatcher() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                let elapsed = ContinuousClock.now - self.lastInboundAt
                if elapsed > Self.idleTimeout {
                    print("[conn \(self.socketID)] idle for \(elapsed) — closing")
                    self.connection.cancel()
                    return
                }
            }
        }
    }

    // MARK: - Read loop

    private func readLoop() async throws {
        while true {
            let headerBytes = try await connection.receiveExactly(PacketHeader.byteCount)
            lastInboundAt = .now
            guard let header = PacketHeader(decoding: headerBytes) else {
                throw NSError(domain: "TestServer", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "short header"
                ])
            }
            let body: Data
            if header.dataLength > 0 {
                body = try await connection.receiveExactly(Int(header.dataLength))
            } else {
                body = Data()
            }
            let fields = PacketCodec.decodeBody(body)
            try await dispatch(header: header, fields: fields)
        }
    }

    // MARK: - Dispatch

    private func dispatch(header: PacketHeader, fields: [PacketField]) async throws {
        switch header.transactionID {
        case 107:   // login
            try await handleLogin(header: header, fields: fields)
        case 121:   // agree (no reply)
            // Nothing to do; client doesn't expect a reply.
            break
        case 109:   // disconnect
            throw NSError(domain: "TestServer", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "client disconnect"
            ])
        case 300:   // user list
            try await handleUserList(header: header)
        case 303:   // user info
            try await handleUserInfo(header: header, fields: fields)
        case 304:   // change nickname (no reply)
            await handleNicknameChange(fields: fields)
        case 105:   // chat (client → server send; server pushes back as 106)
            try await handleChat(header: header, fields: fields)
        case 108:   // sendInstantMessage (private message)
            try await handlePrivateMessage(header: header, fields: fields)
        case 112:   // createPrivateChat (expects reply with chatReference)
            try await handleCreatePrivateChat(header: header, fields: fields)
        case 113:   // invite (no reply)
            await handleInviteToPrivateChat(fields: fields)
        case 114:   // rejectPrivateChat (no reply)
            // Nothing to track — invitations aren't held server-side.
            break
        case 115:   // joinPrivateChat (no reply)
            await handleJoinPrivateChat(fields: fields)
        case 116:   // leavePrivateChat (no reply)
            await handleLeavePrivateChat(fields: fields)
        case 120:   // changeChatSubject (no reply)
            await handleChangePrivateChatSubject(fields: fields)
        case 500:   // 185-style ping
            try await reply(header: header)
        case 101:   // get news list (plain)
            try await handleGetNewsList(header: header)
        case 103:   // post news (plain)
            try await handlePostNews(header: header, fields: fields)
        case 370:   // get threaded news bundles
            try await handleGetBundles(header: header, fields: fields)
        case 371:   // get threaded news category contents
            try await handleGetCategory(header: header, fields: fields)
        case 400:   // get news thread body
            try await handleGetThread(header: header, fields: fields)
        case 410:   // post threaded news (no-reply on the client side)
            try await handlePostThread(header: header, fields: fields)
        case 200:   // list files
            try await handleListFiles(header: header, fields: fields)
        case 202:   // download file
            try await handleDownloadFile(header: header, fields: fields)
        case 203:   // upload file
            try await handleUploadFile(header: header, fields: fields)
        case 204:   // delete entry
            try await handleDeleteEntry(header: header, fields: fields)
        case 205:   // create folder
            try await handleCreateFolder(header: header, fields: fields)
        case 206:   // get file info
            try await handleFileInfo(header: header, fields: fields)
        case 207:   // set file info (rename or comment)
            try await handleSetFileInfo(header: header, fields: fields)
        case 350:   // createLogin
            try await handleCreateLogin(header: header, fields: fields)
        case 351:   // deleteLogin
            try await handleDeleteLogin(header: header, fields: fields)
        case 352:   // openLogin
            try await handleOpenLogin(header: header, fields: fields)
        case 353:   // modifyLogin
            try await handleModifyLogin(header: header, fields: fields)
        default:
            // Unknown — respond with empty success so the client doesn't
            // stall on a missing handler.
            print("[conn \(socketID)] unhandled trans \(header.transactionID)")
            if header.transactionID >= 100 {
                try await reply(header: header)
            }
        }
    }

    // MARK: - Handlers

    private func handleLogin(header: PacketHeader, fields: [PacketField]) async throws {
        let nick = fields.string(.nickname, encoding: encoding) ?? "anon"
        let iconValue = fields.uint16(.icon) ?? 1
        self.nickname = nick
        self.icon = iconValue
        let push: @Sendable (Data) async -> Void = { [weak self] packet in
            guard let self else { return }
            try? await self.connection.sendAsync(packet)
        }
        self.socketID = await state.register(
            nickname: nick,
            icon: iconValue,
            push: push
        )

        // Reply with our advertised version so the client picks the
        // right news capability and the socket id we just allocated so
        // the client knows who it is on the server (used to label its
        // own messages and to ignore self-echoes).
        let version = state.advertisedVersion
        try await reply(
            header: header,
            fields: [
                PacketField.uint16(.clientVersion, version),
                PacketField.uint16(.socket, self.socketID),
                PacketField.string(.serverName, "Heidrun Test Server", encoding: encoding)
            ]
        )

        // Tell every other connected user about the new arrival so
        // their user-list panes refresh and their chat shows the join
        // line. Real Hotline servers push transID 301 (`userChanged`)
        // on login, and 302 (`userLeft`) on disconnect.
        await announceUserChanged()

        // Real Hotline servers push the agreement (transID 109) right
        // after the login reply. Skipped when the server has none
        // configured, matching servers that don't bother with one.
        if let agreement = state.agreement {
            await pushAgreement(agreement)
        }
    }

    /// Push transID 109 (`agreement`) with the server's banner text.
    /// `autoAgree` stays at 0; the client UI still asks the user to
    /// confirm before sending the agree (transID 121) back.
    private func pushAgreement(_ text: String) async {
        let packet = PacketCodec.encode(
            classID: 0,
            transactionID: 109,
            taskNumber: 0,
            fields: [
                PacketField.string(.message, text, encoding: encoding),
                PacketField.uint16(.autoAgree, 0)
            ]
        )
        try? await connection.sendAsync(packet)
    }

    /// Push a transID 301 (`userChanged`) packet describing the current
    /// connection's profile to every connected client. Called on login
    /// (so others see the join) and after a nickname/icon change.
    private func announceUserChanged() async {
        let packet = PacketCodec.encode(
            classID: 0,
            transactionID: 301,
            taskNumber: 0,
            fields: [
                .uint16(.socket, socketID),
                .uint16(.icon, icon),
                .uint16(.status, 0),
                .string(.nickname, nickname, encoding: encoding)
            ]
        )
        await state.broadcast(packet)
    }

    /// Push a transID 302 (`userLeft`) for `socket` to every connected
    /// client. Fired when this connection's read loop ends.
    private func announceUserLeft(socket: UInt16) async {
        let packet = PacketCodec.encode(
            classID: 0,
            transactionID: 302,
            taskNumber: 0,
            fields: [.uint16(.socket, socket)]
        )
        await state.broadcast(packet)
    }

    private func handleUserList(header: PacketHeader) async throws {
        let users = await state.connectedUsers
        let fields = users.map { Encoders.userListEntry($0, encoding: encoding) }
        try await reply(header: header, fields: fields)
    }

    private func handleUserInfo(header: PacketHeader, fields: [PacketField]) async throws {
        let target = fields.uint16(.socket) ?? 0
        guard let user = await state.connectedUsers.first(where: { $0.socket == target }) else {
            try await reply(header: header, errorID: 1)
            return
        }
        try await reply(
            header: header,
            fields: [
                PacketField.string(.nickname, user.nickname, encoding: encoding),
                PacketField.uint16(.icon, user.icon),
                PacketField.uint16(.status, user.status.rawValue),
                PacketField.string(
                    .message,
                    "Test server user — connected via Heidrun-Swift.",
                    encoding: encoding
                )
            ]
        )
    }

    private func handleNicknameChange(fields: [PacketField]) async {
        let nick = fields.string(.nickname, encoding: encoding) ?? nickname
        let icon = fields.uint16(.icon) ?? icon
        self.nickname = nick
        self.icon = icon
        await state.updateUser(socket: socketID, nickname: nick, icon: icon)
        // Push the change so other clients refresh their user-list
        // entries and matching chat sender labels.
        await announceUserChanged()
    }

    /// Forward a private message (transID 108) to the addressed socket
    /// as an `InfoTransaction.message` (104) push, mirroring the way
    /// real Hotline servers relay PMs. The sender's socket is encoded
    /// in the push so the recipient can route it into the right thread.
    private func handlePrivateMessage(header: PacketHeader, fields: [PacketField]) async throws {
        let target = fields.uint16(.socket) ?? 0
        guard let body = fields.string(.message, encoding: encoding), target != 0 else {
            try await reply(header: header, errorID: 1)
            return
        }
        let push = PacketCodec.encode(
            classID: 0,
            transactionID: 104,  // kInfoMsg
            taskNumber: 0,
            fields: [
                PacketField.uint16(.socket, socketID),
                PacketField.string(.message, body, encoding: encoding)
            ]
        )
        let delivered = await state.push(to: target, packet: push)
        try await reply(header: header, errorID: delivered ? 0 : 1)
    }

    private func handleChat(header: PacketHeader, fields: [PacketField]) async throws {
        guard let body = fields.string(.message, encoding: encoding) else {
            try await reply(header: header)
            return
        }
        let line = " \(nickname): \(body)\r"
        let isAction = (fields.uint16(.parameter) ?? 0) != 0
        var pushFields: [PacketField] = [
            PacketField.string(.message, line, encoding: encoding),
            PacketField.uint16(.parameter, isAction ? 1 : 0)
        ]
        // Scope to the addressed room when present, otherwise broadcast
        // to the public chat. The chatReference round-trips so the
        // client can route the line into the right ChatViewModel.
        let chatRef = fields.first(.chatReference)
        if let chatRef {
            pushFields.append(chatRef)
        }
        let push = PacketCodec.encode(
            classID: 0,
            transactionID: 106,  // kInfoChat
            taskNumber: 0,
            fields: pushFields
        )
        if let chatRef {
            let chatID = ChatID(data: chatRef.data).rawValue
            let members = await state.privateChatMembers(chatID)
            await state.push(to: members, packet: push)
        } else {
            await state.broadcast(push)
        }
        try await reply(header: header)
    }

    // MARK: - Private chat rooms

    /// `createPrivateChat` (transID 112): allocate a fresh room, push
    /// an invitation (transID 113) to the addressed user, and reply
    /// with the chatReference so the creator can join their own room.
    private func handleCreatePrivateChat(header: PacketHeader, fields: [PacketField]) async throws {
        let target = fields.uint16(.socket) ?? 0
        let chatID = await state.createPrivateChat(creator: socketID)
        let chatRefData = ChatID(rawValue: chatID).data
        if target != 0 {
            let invitation = PacketCodec.encode(
                classID: 0,
                transactionID: 113,  // kInfoInvitation
                taskNumber: 0,
                fields: [
                    PacketField(key: .chatReference, data: chatRefData),
                    PacketField.uint16(.socket, socketID),
                    PacketField.string(.message, "\(nickname) invites you to chat", encoding: encoding)
                ]
            )
            await state.push(to: target, packet: invitation)
        }
        try await reply(
            header: header,
            fields: [PacketField(key: .chatReference, data: chatRefData)]
        )
    }

    /// `invite` (transID 113): push an invitation to the target socket
    /// for an existing chat. Mirrors `createPrivateChat` but reuses an
    /// already-allocated room.
    private func handleInviteToPrivateChat(fields: [PacketField]) async {
        let target = fields.uint16(.socket) ?? 0
        guard let ref = fields.first(.chatReference), target != 0 else { return }
        let invitation = PacketCodec.encode(
            classID: 0,
            transactionID: 113,
            taskNumber: 0,
            fields: [
                ref,
                PacketField.uint16(.socket, socketID),
                PacketField.string(.message, "\(nickname) invites you to chat", encoding: encoding)
            ]
        )
        await state.push(to: target, packet: invitation)
    }

    /// `joinPrivateChat` (transID 115): add this connection to the
    /// room, push a `privateChatJoined` (117) for every existing member
    /// to the joiner so they populate their roster, then push a
    /// matching 117 carrying the joiner to every other member so their
    /// rosters update in turn.
    private func handleJoinPrivateChat(fields: [PacketField]) async {
        guard let ref = fields.first(.chatReference) else { return }
        let chatID = ChatID(data: ref.data).rawValue
        let existing = await state.privateChatMembers(chatID).subtracting([socketID])
        await state.joinPrivateChat(chatID, socket: socketID)
        let users = await state.connectedUsers
        // Hydrate the joiner's roster.
        for socket in existing {
            guard let user = users.first(where: { $0.socket == socket }) else { continue }
            let push = PacketCodec.encode(
                classID: 0,
                transactionID: 117,
                taskNumber: 0,
                fields: [
                    ref,
                    Encoders.userListEntry(user, encoding: encoding)
                ]
            )
            await state.push(to: socketID, packet: push)
        }
        // Notify everyone else that the joiner has arrived.
        if let me = users.first(where: { $0.socket == socketID }) {
            let push = PacketCodec.encode(
                classID: 0,
                transactionID: 117,
                taskNumber: 0,
                fields: [
                    ref,
                    Encoders.userListEntry(me, encoding: encoding)
                ]
            )
            await state.push(to: existing, packet: push)
        }
    }

    /// `leavePrivateChat` (transID 116): drop membership and tell the
    /// remaining members so their participant lists stay accurate.
    private func handleLeavePrivateChat(fields: [PacketField]) async {
        guard let ref = fields.first(.chatReference) else { return }
        let chatID = ChatID(data: ref.data).rawValue
        let remaining = await state.privateChatMembers(chatID).subtracting([socketID])
        await state.leavePrivateChat(chatID, socket: socketID)
        let push = PacketCodec.encode(
            classID: 0,
            transactionID: 118,
            taskNumber: 0,
            fields: [
                ref,
                PacketField.uint16(.socket, socketID)
            ]
        )
        await state.push(to: remaining, packet: push)
    }

    /// `changeChatSubject` (transID 120): update the room's subject
    /// and push a notification (119) to everyone currently in it.
    private func handleChangePrivateChatSubject(fields: [PacketField]) async {
        guard let ref = fields.first(.chatReference) else { return }
        let chatID = ChatID(data: ref.data).rawValue
        let subject = fields.string(.chatSubject, encoding: encoding) ?? ""
        await state.setPrivateChatSubject(chatID, subject: subject)
        let push = PacketCodec.encode(
            classID: 0,
            transactionID: 119,
            taskNumber: 0,
            fields: [
                ref,
                PacketField.string(.chatSubject, subject, encoding: encoding)
            ]
        )
        let members = await state.privateChatMembers(chatID)
        await state.push(to: members, packet: push)
    }

    // MARK: News — plain

    private func handleGetNewsList(header: PacketHeader) async throws {
        let blob = await state.plainFeedJoined
        try await reply(
            header: header,
            fields: [PacketField.string(.message, blob, encoding: encoding)]
        )
    }

    private func handlePostNews(header: PacketHeader, fields: [PacketField]) async throws {
        guard let post = fields.string(.message, encoding: encoding) else {
            try await reply(header: header)
            return
        }
        let stamped = "[\(nickname)] \(post)"
        await state.appendPlainPost(stamped)
        try await reply(header: header)

        let push = PacketCodec.encode(
            classID: 0,
            transactionID: 102,  // kInfoNewPost
            taskNumber: 0,
            fields: [PacketField.string(.message, stamped, encoding: encoding)]
        )
        await state.broadcast(push)
    }

    // MARK: News — threaded

    private func handleGetBundles(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeNewsPath(from: fields)
        guard let nodes = await state.threaded.children(at: path) else {
            try await reply(header: header, errorID: 1)
            return
        }
        let entries: [PacketField] = nodes.map { node in
            let count = UInt16(clamping: node.kind == .bundle ? node.children.count : node.threads.count)
            return Encoders.newsBundleEntry(
                name: node.name,
                kind: node.kind,
                itemCount: count,
                encoding: encoding
            )
        }
        try await reply(header: header, fields: entries)
    }

    private func handleGetCategory(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeNewsPath(from: fields)
        guard let posts = await state.threaded.threads(at: path) else {
            try await reply(header: header, errorID: 1)
            return
        }
        try await reply(
            header: header,
            fields: [Encoders.newsThreadList(posts, encoding: encoding)]
        )
    }

    private func handlePostThread(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeNewsPath(from: fields)
        let title = fields.string(.newsTitle, encoding: encoding) ?? "(untitled)"
        let body  = fields.string(.newsData, encoding: encoding) ?? ""
        let post = Post(title: title, author: nickname, body: body)
        let ok = await state.appendThreadedPost(at: path, post: post)
        print("[conn \(socketID)] post 410 path=\(path) title=\(title.prefix(40)) -> \(ok ? "OK" : "FAIL")")
        // Client uses sendNoReply for 410, but acknowledging is harmless
        // and keeps parity with real Hotline servers (which do reply).
        try await reply(header: header, errorID: ok ? 0 : 1)
    }

    private func handleGetThread(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeNewsPath(from: fields)
        let articleID = fields.uint16(.newsArticleID) ?? 0
        guard articleID > 0,
              let posts = await state.threaded.threads(at: path),
              Int(articleID) <= posts.count else {
            try await reply(header: header, errorID: 1)
            return
        }
        let post = posts[Int(articleID) - 1]
        try await reply(
            header: header,
            fields: [
                PacketField.string(.newsTitle, post.title, encoding: encoding),
                PacketField.string(.newsAuthor, post.author, encoding: encoding),
                PacketField.string(.newsType, "text/plain", encoding: encoding),
                PacketField.string(.newsData, post.body, encoding: encoding)
            ]
        )
    }

    // MARK: - File system

    private func handleListFiles(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let listing = state.vfs.list(at: path) else {
            try await reply(header: header, errorID: 1)
            return
        }
        let entries = listing.map { FileEncoders.fileListEntry($0, encoding: encoding) }
        try await reply(header: header, fields: entries)
    }

    private func handleDownloadFile(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: encoding) else {
            try await reply(header: header, errorID: 1)
            return
        }
        guard let bytes = state.vfs.bytes(at: path, name: name) else {
            try await reply(header: header, errorID: 1)
            return
        }
        var offset: UInt32 = 0
        if let resumeField = fields.first(.fileResumeInfo),
           let info = ResumeInfoCodec.decode(resumeField.data) {
            offset = info.dataForkOffset
        }
        let remaining = UInt32(clamping: max(0, bytes.count - Int(offset)))
        let transferID = await state.registerTransfer(
            .download(path: path, name: name, dataForkOffset: offset)
        )
        try await reply(
            header: header,
            fields: [
                .uint32(.transferID, transferID),
                .uint32(.transferSize, remaining)
            ]
        )
    }

    private func handleUploadFile(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: encoding) else {
            try await reply(header: header, errorID: 1)
            return
        }
        let declaredSize = fields.uint32(.transferSize) ?? 0
        let resume = (fields.uint16(.parameter) ?? 0) == 1
        let transferID = await state.registerTransfer(
            .upload(path: path, name: name, size: declaredSize, resume: resume)
        )
        try await reply(
            header: header,
            fields: [.uint32(.transferID, transferID)]
        )
    }

    private func handleDeleteEntry(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: encoding) else {
            try await reply(header: header, errorID: 1)
            return
        }
        let ok = state.vfs.delete(at: path, name: name)
        try await reply(header: header, errorID: ok ? 0 : 1)
    }

    private func handleCreateFolder(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: encoding) else {
            try await reply(header: header, errorID: 1)
            return
        }
        let ok = state.vfs.createFolder(at: path, name: name)
        try await reply(header: header, errorID: ok ? 0 : 1)
    }

    private func handleFileInfo(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: encoding) else {
            try await reply(header: header, errorID: 1)
            return
        }
        guard let (entry, meta) = state.vfs.info(at: path, name: name) else {
            try await reply(header: header, errorID: 1)
            return
        }
        var out: [PacketField] = [
            PacketField.string(.fileName, entry.name, encoding: encoding),
            PacketField(key: .longFileType, data: FileEncoders.longFourCC(entry.type)),
            PacketField(key: .longFileCreator, data: FileEncoders.longFourCC(entry.creator)),
            .uint32(.fileSize, entry.size),
            FileEncoders.dateField(meta.created, key: .fileCreationDate),
            FileEncoders.dateField(meta.modified, key: .fileModificationDate)
        ]
        if !meta.comment.isEmpty {
            out.append(.string(.fileComment, meta.comment, encoding: encoding))
        }
        try await reply(header: header, fields: out)
    }

    private func handleSetFileInfo(header: PacketHeader, fields: [PacketField]) async throws {
        let path = decodeFilePath(from: fields)
        guard let name = fields.string(.fileName, encoding: encoding) else {
            try await reply(header: header, errorID: 1)
            return
        }
        if let newName = fields.string(.fileRename, encoding: encoding), !newName.isEmpty {
            let ok = state.vfs.rename(at: path, from: name, to: newName)
            try await reply(header: header, errorID: ok ? 0 : 1)
            return
        }
        if let comment = fields.string(.fileComment, encoding: encoding) {
            let ok = state.vfs.setComment(at: path, name: name, comment: comment)
            try await reply(header: header, errorID: ok ? 0 : 1)
            return
        }
        try await reply(header: header)
    }

    // MARK: - Account admin

    private func handleCreateLogin(header: PacketHeader, fields: [PacketField]) async throws {
        let login = obfuscatedString(.login, from: fields) ?? ""
        let password = obfuscatedString(.password, from: fields) ?? ""
        let nickname = fields.string(.nickname, encoding: encoding) ?? ""
        let privileges = privilegesField(from: fields)
        guard !login.isEmpty else {
            try await reply(header: header, errorID: 1, errorMessage: "login required")
            return
        }
        let account = ServerAccount(login: login, password: password, nickname: nickname, privileges: privileges)
        do {
            try await state.adminCreate(account)
            try await reply(header: header)
        } catch AccountStoreError.duplicate(let name) {
            try await reply(header: header, errorID: 1, errorMessage: "account \(name) already exists")
        } catch {
            try await reply(header: header, errorID: 1, errorMessage: "internal error: \(error.localizedDescription)")
        }
    }

    private func handleDeleteLogin(header: PacketHeader, fields: [PacketField]) async throws {
        let login = obfuscatedString(.login, from: fields) ?? ""
        guard !login.isEmpty else {
            try await reply(header: header, errorID: 1, errorMessage: "login required")
            return
        }
        do {
            try await state.adminDelete(login: login)
            try await reply(header: header)
        } catch AccountStoreError.missing(let name) {
            try await reply(header: header, errorID: 1, errorMessage: "account \(name) not found")
        } catch {
            try await reply(header: header, errorID: 1, errorMessage: "internal error: \(error.localizedDescription)")
        }
    }

    private func handleOpenLogin(header: PacketHeader, fields: [PacketField]) async throws {
        // The 352 transaction sends the login PLAIN (not obfuscated) —
        // matches HEClient.m line 995 and our client at HotlineNetworkClient.swift:549.
        let login = fields.string(.login, encoding: encoding) ?? ""
        guard let account = await state.adminOpen(login: login) else {
            try await reply(header: header, errorID: 1, errorMessage: "account not found")
            return
        }
        try await reply(
            header: header,
            fields: [
                .string(.nickname, account.nickname, encoding: encoding),
                PacketField(key: .privileges, data: Data(account.privileges.bytes))
            ]
        )
    }

    private func handleModifyLogin(header: PacketHeader, fields: [PacketField]) async throws {
        let login = obfuscatedString(.login, from: fields) ?? ""
        let nickname = fields.string(.nickname, encoding: encoding) ?? ""
        let privileges = privilegesField(from: fields)
        let password = modifyPasswordField(from: fields)
        guard !login.isEmpty else {
            try await reply(header: header, errorID: 1, errorMessage: "login required")
            return
        }
        do {
            try await state.adminModify(login: login, password: password, nickname: nickname, privileges: privileges)
            try await reply(header: header)
        } catch AccountStoreError.missing(let name) {
            try await reply(header: header, errorID: 1, errorMessage: "account \(name) not found")
        } catch {
            try await reply(header: header, errorID: 1, errorMessage: "internal error: \(error.localizedDescription)")
        }
    }

    /// Read an obfuscated string field (login / password): each byte is
    /// XOR'd with `0xFF` on the wire; decoding inverts that.
    private func obfuscatedString(_ key: HotlineObjectKey, from fields: [PacketField]) -> String? {
        guard let field = fields.first(key) else { return nil }
        var bytes = Array(field.data)
        for index in bytes.indices {
            bytes[index] ^= 0xFF
        }
        return String(data: Data(bytes), encoding: encoding)
    }

    private func privilegesField(from fields: [PacketField]) -> UserPrivileges {
        guard let field = fields.first(.privileges) else { return [] }
        return UserPrivileges(bytes: Array(field.data))
    }

    /// Mirror the client's `modifyLogin` password convention:
    /// - missing field   → `nil` (keep existing)
    /// - single 0x00     → `""` (clear)
    /// - non-empty obfuscated string → that string
    private func modifyPasswordField(from fields: [PacketField]) -> String? {
        guard let field = fields.first(.password) else { return nil }
        if field.data == Data([0x00]) { return "" }
        var bytes = Array(field.data)
        for index in bytes.indices { bytes[index] ^= 0xFF }
        return String(data: Data(bytes), encoding: encoding)
    }

    // MARK: - Helpers

    /// Decode the `filePath` (202) field into a list of components.
    private func decodeFilePath(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.filePath), field.data.count >= 2 else { return [] }
        return decodeNamePath(field.data)
    }

    /// Shared decoder for the `RemotePath` wire format used by both
    /// `filePath` (202) and `newsPath` (325): UInt16 component count,
    /// per-component (UInt16 0 pad, UInt8 length, name bytes).
    private func decodeNamePath(_ data: Data) -> [String] {
        var cursor = 0
        func readUInt16BE() -> UInt16? {
            guard cursor + 2 <= data.count else { return nil }
            let value = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
            cursor += 2
            return value
        }
        func readUInt8() -> UInt8? {
            guard cursor < data.count else { return nil }
            let value = data[cursor]
            cursor += 1
            return value
        }
        guard let count = readUInt16BE() else { return [] }
        var components: [String] = []
        for _ in 0..<count {
            _ = readUInt16BE()                          // reserved
            guard let len = readUInt8() else { break }
            guard cursor + Int(len) <= data.count else { break }
            let name = String(data: data[cursor..<cursor + Int(len)], encoding: encoding) ?? ""
            cursor += Int(len)
            components.append(name)
        }
        return components
    }

    /// Decode the `newsPath` (325) field into a list of components.
    private func decodeNewsPath(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.newsPath), field.data.count >= 2 else { return [] }
        return decodeNamePath(field.data)
    }

    /// Send a server-to-client reply with the same task number the client
    /// used. `errorID == 1` is the standard Hotline failure marker; the
    /// optional `errorMessage` is encoded as `.errorMessage` (key 100)
    /// when supplied.
    private func reply(
        header: PacketHeader,
        errorID: UInt32 = 0,
        errorMessage: String? = nil,
        fields: [PacketField] = []
    ) async throws {
        var replyFields = fields
        if let errorMessage {
            replyFields.append(.string(.errorMessage, errorMessage, encoding: encoding))
        }
        let packet = PacketCodec.encode(
            classID: 1,
            transactionID: header.transactionID,
            taskNumber: header.taskNumber,
            errorID: errorID,
            fields: replyFields
        )
        try await connection.sendAsync(packet)
    }
}
