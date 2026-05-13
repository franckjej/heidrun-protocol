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

    init(connection: NWConnection, state: ServerState, queue: DispatchQueue) {
        self.connection = connection
        self.state = state
        self.queue = queue
    }

    func run() async {
        do {
            try await connection.startAndWaitForReady(on: queue)
            try await handshake()
            try await readLoop()
        } catch {
            print("[conn \(socketID)] closed: \(error)")
        }
        await state.unregister(socket: socketID)
        connection.cancel()
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

    // MARK: - Read loop

    private func readLoop() async throws {
        while true {
            let headerBytes = try await connection.receiveExactly(PacketHeader.byteCount)
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
        case 305:   // chat
            try await handleChat(header: header, fields: fields)
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
        // right news capability.
        let version = await state.advertisedVersion
        try await reply(
            header: header,
            fields: [
                PacketField.uint16(.clientVersion, version),
                PacketField.string(.serverName, "Heidrun Test Server", encoding: encoding)
            ]
        )
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
    }

    private func handleChat(header: PacketHeader, fields: [PacketField]) async throws {
        guard let body = fields.string(.message, encoding: encoding) else {
            try await reply(header: header)
            return
        }
        let line = " \(nickname): \(body)\r"
        let push = PacketCodec.encode(
            classID: 0,
            transactionID: 106,  // kInfoChat
            taskNumber: 0,
            fields: [PacketField.string(.message, line, encoding: encoding)]
        )
        await state.broadcast(push)
        try await reply(header: header)
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

    // MARK: - Helpers

    /// Decode the `newsPath` (325) field into a list of components.
    private func decodeNewsPath(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.newsPath), field.data.count >= 2 else { return [] }
        let data = field.data
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

    /// Send a server-to-client reply with the same task number the client
    /// used. `errorID == 1` is the standard Hotline failure marker.
    private func reply(
        header: PacketHeader,
        errorID: UInt32 = 0,
        fields: [PacketField] = []
    ) async throws {
        let packet = PacketCodec.encode(
            classID: 1,
            transactionID: header.transactionID,
            taskNumber: header.taskNumber,
            errorID: errorID,
            fields: fields
        )
        try await connection.sendAsync(packet)
    }
}
