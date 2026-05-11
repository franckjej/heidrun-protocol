import Foundation
import Network

/// Concrete `HotlineClient` over `Network.framework`'s `NWConnection`.
///
/// The actor owns a single TCP connection plus the read loop that pumps
/// incoming packets into either pending-reply continuations or the
/// `events` broadcaster. Outbound transactions assemble through the
/// shared `PacketCodec` helpers and are written with `sendAsync`.
///
/// The set of operations this implementation actually wires up is the
/// minimum needed to demonstrate end-to-end behaviour against a real
/// server: handshake, login, agreement, ping, chat, user list, broadcast,
/// private messages, nickname change, disconnect. Everything else throws
/// `HotlineError.notImplemented` for now — same protocol surface, more
/// transactions to come.
public actor HotlineNetworkClient: HotlineClient {

    // MARK: - Stored state

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let broadcaster: EventBroadcaster
    private let stringEncoding: String.Encoding
    private let connectionSettings: ConnectionSettings

    private var nextTaskNumber: UInt32 = 1
    private var pendingReplies: [UInt32: CheckedContinuation<[PacketField], Error>] = [:]
    private var connectionSocket: UInt16 = 0
    private var protocolVersion: Int = 0
    private var serverVersion: Int = 0
    private var clientVersion: Int = 151
    private var readerTask: Task<Void, Never>?
    private var torn = false
    private var activeTransfers: [UInt32: FileTransferActor] = [:]

    // MARK: - HotlineClient surface

    public nonisolated var events: AsyncStream<HotlineEvent> {
        broadcaster.makeStream()
    }

    public var connectionInfo: HotlineConnectionInfo {
        HotlineConnectionInfo(
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            connectionSocket: connectionSocket,
            lastTaskNumber: nextTaskNumber &- 1,
            settings: connectionSettings
        )
    }

    // MARK: - Lifecycle

    /// Open a TCP connection, perform the Hotline magic-byte handshake,
    /// and return a ready-to-use client. The caller still has to call
    /// `login(...)` to get past the server's auth gate.
    public static func connect(
        settings: ConnectionSettings,
        stringEncoding: String.Encoding = .macOSRoman
    ) async throws -> HotlineNetworkClient {
        let host = NWEndpoint.Host(settings.address)
        guard let port = NWEndpoint.Port(rawValue: settings.port) else {
            throw HotlineError.notConnected
        }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let queue = DispatchQueue(label: "Heidrun.HotlineNetworkClient")
        try await connection.startAndWaitForReady(on: queue)
        try await Self.performHandshake(on: connection)

        let client = HotlineNetworkClient(
            connection: connection,
            queue: queue,
            settings: settings,
            stringEncoding: stringEncoding
        )
        await client.startReader()
        return client
    }

    private init(
        connection: NWConnection,
        queue: DispatchQueue,
        settings: ConnectionSettings,
        stringEncoding: String.Encoding
    ) {
        self.connection = connection
        self.queue = queue
        self.connectionSettings = settings
        self.stringEncoding = stringEncoding
        self.broadcaster = EventBroadcaster()
    }

    // MARK: - Handshake

    /// Wire bytes:
    ///   client → server "TRTPHOTL\0\1\0\2"   (12 bytes)
    ///   server → client "TRTP" + UInt32 errorCode (8 bytes; 0 means OK)
    private static func performHandshake(on connection: NWConnection) async throws {
        let magic: [UInt8] = [
            0x54, 0x52, 0x54, 0x50,       // 'TRTP'
            0x48, 0x4F, 0x54, 0x4C,       // 'HOTL'
            0x00, 0x01,                   // version 1
            0x00, 0x02                    // sub-version 2
        ]
        try await connection.sendAsync(Data(magic))

        let reply = try await connection.receiveExactly(8)
        let serverMagic = reply.prefix(4)
        guard serverMagic == Data([0x54, 0x52, 0x54, 0x50]) else {
            throw HotlineError.malformedReply(reason: "handshake magic mismatch")
        }
        var cursor = ByteCursor(data: reply, offset: 4)
        let errorCode: UInt32 = cursor.readBigEndian()
        if errorCode != 0 {
            throw HotlineError.serverError(id: errorCode, message: "handshake refused")
        }
    }

    private func startReader() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.runReadLoop()
        }
    }

    private func runReadLoop() async {
        while !torn {
            do {
                let headerData = try await connection.receiveExactly(PacketHeader.byteCount)
                guard let header = PacketHeader(decoding: headerData) else {
                    throw HotlineError.malformedReply(reason: "short header")
                }
                let body: Data
                if header.dataLength > 0 {
                    body = try await connection.receiveExactly(Int(header.dataLength))
                } else {
                    body = Data()
                }
                await dispatch(header: header, body: body)
            } catch {
                await tearDown(with: error)
                return
            }
        }
    }

    private func dispatch(header: PacketHeader, body: Data) {
        let fields = PacketCodec.decodeBody(body)

        // Reply correlation: if we have a pending continuation for this
        // task number, hand it the fields (or surface the server error).
        if let continuation = pendingReplies.removeValue(forKey: header.taskNumber) {
            if header.errorID != 0 {
                let message = fields.string(.errorMessage, encoding: stringEncoding)
                continuation.resume(throwing: HotlineError.serverError(id: header.errorID, message: message))
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
            broadcaster.yield(.privateChatSubjectChanged(
                chat: ChatID(data: ref.data),
                subject: fields.string(.chatSubject, encoding: stringEncoding) ?? ""
            ))

        case .transferQueueUpdate:
            broadcaster.yield(.transferQueueUpdated)

        case .userChanged:
            let user = User(
                socket: fields.uint16(.socket) ?? 0,
                icon: fields.uint16(.icon) ?? 0,
                status: UserStatus(rawValue: fields.uint16(.status) ?? 0),
                privileges: [],
                nickname: fields.string(.nickname, encoding: stringEncoding) ?? ""
            )
            broadcaster.yield(.userChanged(user: user))

        case .userLeft:
            broadcaster.yield(.userLeft(socket: fields.uint16(.socket) ?? 0))

        case .userList:
            let users = fields
                .filter { $0.key == HotlineObjectKey.userListEntry.rawValue }
                .compactMap { UserListEntryCodec.decode($0.data, encoding: stringEncoding) }
            broadcaster.yield(.userListReceived(users: users))

        case .broadcast:
            let text = fields.string(.message, encoding: stringEncoding) ?? ""
            broadcaster.yield(.broadcastReceived(message: text))
        }
    }

    private func tearDown(with error: Error?) async {
        guard !torn else { return }
        torn = true
        connection.cancel()
        // Fail every pending request.
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

    /// Send a request and either return its reply fields (when the
    /// transaction expects a reply) or resolve immediately after the
    /// bytes leave the wire (when it doesn't).
    private func send(
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

        if expectsReply {
            return try await withCheckedThrowingContinuation { cont in
                pendingReplies[taskNumber] = cont
                Task {
                    do {
                        try await connection.sendAsync(packet)
                    } catch {
                        if let resumer = pendingReplies.removeValue(forKey: taskNumber) {
                            resumer.resume(throwing: error)
                        }
                    }
                }
            }
        } else {
            try await connection.sendAsync(packet)
            return []
        }
    }

    @discardableResult
    private func sendNoReply(transactionID: UInt16, fields: [PacketField]) async throws -> [PacketField] {
        try await send(transactionID: transactionID, fields: fields, expectsReply: false)
    }

    @discardableResult
    private func sendExpectingReply(transactionID: UInt16, fields: [PacketField]) async throws -> [PacketField] {
        try await send(transactionID: transactionID, fields: fields, expectsReply: true)
    }

    // MARK: - Lifecycle ops

    public func disconnect() async {
        await tearDown(with: nil)
    }

    public func requestAttention(_ flags: AttentionFlags) async {
        // Host-side concept; nothing to send over the wire.
    }

    // MARK: - Authentication & presence

    public func sendPing() async throws {
        // 185Ping uses transID 500.
        try await sendNoReply(transactionID: 500, fields: [])
    }

    public func login(name: String, password: String, nickname: String, icon: UInt16) async throws {
        let fields: [PacketField] = [
            .obfuscatedString(.login,    name,     encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname,           encoding: stringEncoding),
            .uint16(.icon, icon == 0 ? 1 : icon),
            .uint16(.clientVersion, UInt16(clientVersion))
        ]
        let reply = try await sendExpectingReply(transactionID: 107, fields: fields)
        if let server = reply.uint16(.clientVersion) {
            self.serverVersion = Int(server)
        }
    }

    public func agreeToAgreement(nickname: String, icon: UInt16) async throws {
        let fields: [PacketField] = [
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon)
        ]
        try await sendNoReply(transactionID: 121, fields: fields)
    }

    public func changeNickname(_ nickname: String, icon: UInt16, persist: Bool) async throws {
        let fields: [PacketField] = [
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon)
        ]
        try await sendNoReply(transactionID: 304, fields: fields)
    }

    // MARK: - User list

    public func fetchUserList() async throws -> [User] {
        let reply = try await sendExpectingReply(transactionID: 300, fields: [])
        return reply
            .filter { $0.key == HotlineObjectKey.userListEntry.rawValue }
            .compactMap { UserListEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    public func fetchUserInfo(socket: UInt16) async throws -> UserInfo {
        let reply = try await sendExpectingReply(
            transactionID: 303,
            fields: [.uint16(.socket, socket)]
        )
        let user = User(
            socket: socket,
            icon: reply.uint16(.icon) ?? 0,
            status: UserStatus(rawValue: reply.uint16(.status) ?? 0),
            privileges: [],
            nickname: reply.string(.nickname, encoding: stringEncoding) ?? ""
        )
        let infoText = reply.string(.message, encoding: stringEncoding) ?? ""
        return UserInfo(user: user, infoText: infoText)
    }

    public func kick(socket: UInt16, ban: Bool) async throws {
        var fields: [PacketField] = [.uint16(.socket, socket)]
        if ban { fields.append(.uint16(.banFlag, 1)) }
        try await sendExpectingReply(transactionID: 110, fields: fields)
    }

    // MARK: - Direct messages

    public func broadcast(_ message: String) async throws {
        try await sendExpectingReply(
            transactionID: 355,
            fields: [.string(.message, message, encoding: stringEncoding)]
        )
    }

    public func sendPrivateMessage(_ message: String, to socket: UInt16) async throws {
        let fields: [PacketField] = [
            .uint16(.socket, socket),
            .string(.message, message, encoding: stringEncoding)
        ]
        try await sendExpectingReply(transactionID: 108, fields: fields)
    }

    // MARK: - Public & private chat

    public func sendChat(_ message: String, in chat: ChatID?, isAction: Bool) async throws {
        var fields: [PacketField] = [
            .string(.message, message, encoding: stringEncoding)
        ]
        if let chat {
            fields.append(PacketField(key: .chatReference, data: chat.data))
        }
        fields.append(.uint16(.parameter, isAction ? 1 : 0))
        try await sendNoReply(transactionID: 105, fields: fields)
    }

    public func createPrivateChat(with socket: UInt16) async throws -> ChatID {
        let reply = try await sendExpectingReply(
            transactionID: 112,
            fields: [.uint16(.socket, socket)]
        )
        guard let ref = reply.first(.chatReference) else {
            throw HotlineError.malformedReply(reason: "missing chat reference")
        }
        return ChatID(data: ref.data)
    }

    public func joinPrivateChat(_ chat: ChatID) async throws {
        try await sendNoReply(
            transactionID: 115,
            fields: [PacketField(key: .chatReference, data: chat.data)]
        )
    }

    public func rejectPrivateChat(_ chat: ChatID) async throws {
        // transID 114 (kNoReplyRejectPC) per HEClient.m line 727.
        try await sendNoReply(
            transactionID: 114,
            fields: [PacketField(key: .chatReference, data: chat.data)]
        )
    }

    public func leavePrivateChat(_ chat: ChatID) async throws {
        try await sendNoReply(
            transactionID: 116,
            fields: [PacketField(key: .chatReference, data: chat.data)]
        )
    }

    public func changeChatSubject(_ subject: String, in chat: ChatID) async throws {
        let fields: [PacketField] = [
            PacketField(key: .chatReference, data: chat.data),
            .string(.chatSubject, subject, encoding: stringEncoding)
        ]
        try await sendNoReply(transactionID: 120, fields: fields)
    }

    public func invite(socket: UInt16, to chat: ChatID) async throws {
        // transID 113 (kNoReplyAddToPChat) per HEClient.m line 684.
        let fields: [PacketField] = [
            .uint16(.socket, socket),
            PacketField(key: .chatReference, data: chat.data)
        ]
        try await sendNoReply(transactionID: 113, fields: fields)
    }

    // MARK: - Plain news

    public func fetchNewsFeed() async throws -> String {
        // getNewsList: transID 101, no objects.
        let reply = try await sendExpectingReply(transactionID: 101, fields: [])
        return reply.string(.message, encoding: stringEncoding) ?? ""
    }

    public func postPlainNews(_ text: String) async throws {
        // postNewNews: transID 103, message(101).
        try await sendExpectingReply(
            transactionID: 103,
            fields: [.string(.message, text, encoding: stringEncoding)]
        )
    }

    // MARK: - Account administration

    public func createLogin(name: String, password: String, nickname: String, privileges: UserPrivileges) async throws {
        // transID 350, no-reply, [login(105 obfusc), password(106 obfusc), nick(102), privs(110, 8 bytes)].
        let fields: [PacketField] = [
            .obfuscatedString(.login,    name,     encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: stringEncoding),
            PacketField(key: .privileges, data: Data(privileges.bytes))
        ]
        try await sendNoReply(transactionID: 350, fields: fields)
    }

    public func deleteLogin(_ name: String) async throws {
        // transID 351, no-reply, [login(105 obfusc)].
        try await sendNoReply(
            transactionID: 351,
            fields: [.obfuscatedString(.login, name, encoding: stringEncoding)]
        )
    }

    public func openLogin(_ name: String) async throws -> (nickname: String, privileges: UserPrivileges) {
        // transID 352, reply. Login here is NOT obfuscated (per HEClient.m line 995).
        let reply = try await sendExpectingReply(
            transactionID: 352,
            fields: [.string(.login, name, encoding: stringEncoding)]
        )
        let nickname = reply.string(.nickname, encoding: stringEncoding) ?? ""
        let privsField = reply.first(.privileges)
        let privileges = privsField.map { UserPrivileges(bytes: Array($0.data)) } ?? []
        return (nickname: nickname, privileges: privileges)
    }

    public func modifyLogin(name: String, password: String?, nickname: String, privileges: UserPrivileges) async throws {
        // transID 353, no-reply.
        // - nickname (102), login (105 obfusc) are always sent.
        // - password (106): omitted when nil; sent obfuscated when non-empty;
        //   sent as a single 0x00 byte for an empty new password (mirrors
        //   the noPass / emptyPass branch in HEClient.m line 1054).
        // - privileges (110, 8 bytes) is always sent.
        var fields: [PacketField] = [
            .string(.nickname, nickname, encoding: stringEncoding),
            .obfuscatedString(.login, name, encoding: stringEncoding)
        ]
        if let password {
            if password.isEmpty {
                fields.append(PacketField(key: .password, data: Data([0x00])))
            } else {
                fields.append(.obfuscatedString(.password, password, encoding: stringEncoding))
            }
        }
        fields.append(PacketField(key: .privileges, data: Data(privileges.bytes)))
        try await sendNoReply(transactionID: 353, fields: fields)
    }

    // MARK: - Threaded news

    public func fetchNewsBundles(at path: RemotePath, isCategory: Bool) async throws -> [NewsBundle] {
        // transID 370 for bundles, 371 for categories. Reply contains
        // 0+ newsBundleEntry(323) fields, each decodable into NewsBundle
        // via NewsBundleEntryCodec.
        let transactionID: UInt16 = isCategory ? 371 : 370
        let reply = try await sendExpectingReply(
            transactionID: transactionID,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
        return reply
            .filter { $0.key == HotlineObjectKey.newsBundleEntry.rawValue }
            .compactMap { NewsBundleEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    public func fetchNewsThread(at path: RemotePath, threadID: UInt16, type: String) async throws -> NewsThread {
        // transID 400, [newsPath(325), articleID(326), type(327)].
        // Reply carries a single thread's fields: parent/prev/next ids,
        // post date(330), and one element with type(327), title(328),
        // author(329), data(333). HEClientReceive.m parses them one by
        // one and stuffs them into a dictionary; we collapse to a typed
        // NewsThread with a single ThreadElement.
        let reply = try await sendExpectingReply(
            transactionID: 400,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, threadID),
                .string(.newsType, type, encoding: stringEncoding)
            ]
        )
        let parentID = reply.uint16(.newsParentThread) ?? 0
        let postDate = reply.date(.newsDate) ?? Date.distantPast

        var elements: [ThreadElement] = []
        let elementTitle = reply.string(.newsTitle, encoding: stringEncoding)
        let elementBody  = reply.string(.newsData,  encoding: stringEncoding)
        if elementTitle != nil || elementBody != nil {
            let bodyBytes = reply.first(.newsData)?.data.count ?? 0
            elements.append(ThreadElement(
                title: elementTitle ?? "",
                author: reply.string(.newsAuthor, encoding: stringEncoding) ?? "",
                mimeType: reply.string(.newsType, encoding: stringEncoding) ?? ThreadElement.plainTextType,
                size: UInt16(clamping: bodyBytes)
            ))
        }

        return NewsThread(
            threadID: threadID,
            parentID: parentID,
            postDate: postDate,
            elements: elements
        )
    }

    public func deleteNewsBundle(at path: RemotePath) async throws {
        // transID 380, no-reply, [newsPath(325)].
        try await sendNoReply(
            transactionID: 380,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
    }

    public func deleteNewsThread(at path: RemotePath, threadID: UInt16, cascade: Bool) async throws {
        // transID 411, no-reply, [newsPath(325), articleID(326), deleteAll(337)].
        try await sendNoReply(
            transactionID: 411,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, threadID),
                .uint16(.newsDeleteAll, cascade ? 1 : 0)
            ]
        )
    }

    public func createNewsBundle(at path: RemotePath, name: String, isCategory: Bool) async throws {
        // transID 381 for bundles, 382 for categories.
        // For a bundle the name uses fileName (201); for a category it uses
        // newsCategoryName (322), per HEClient.m line 1229.
        let transactionID: UInt16 = isCategory ? 382 : 381
        let nameKey: HotlineObjectKey = isCategory ? .newsCategoryName : .fileName
        try await sendNoReply(
            transactionID: transactionID,
            fields: [
                .string(nameKey, name, encoding: stringEncoding),
                .path(.newsPath, path, encoding: stringEncoding)
            ]
        )
    }

    public func postNewsThread(
        at path: RemotePath,
        parentThreadID: UInt16,
        title: String,
        type: String,
        body: String
    ) async throws {
        // transID 410, no-reply, 6 fields:
        //   newsPath(325), articleID(326), title(328), articleFlags(334=0),
        //   type(327), body(333).
        try await sendNoReply(
            transactionID: 410,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, parentThreadID),
                .string(.newsTitle, title, encoding: stringEncoding),
                .uint16(.newsArticleFlags, 0),
                .string(.newsType, type, encoding: stringEncoding),
                .string(.newsData, body, encoding: stringEncoding)
            ]
        )
    }

    // MARK: - File system

    public func listFiles(at path: RemotePath) async throws -> [RemoteFile] {
        // transID 200, reply, [filePath(202)].
        let reply = try await sendExpectingReply(
            transactionID: 200,
            fields: [.path(.filePath, path, encoding: stringEncoding)]
        )
        return reply
            .filter { $0.key == HotlineObjectKey.fileListEntry.rawValue }
            .compactMap { FileListEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    public func deleteEntry(at path: RemotePath, name: String) async throws {
        // transID 204, no-reply, [name(201), filePath(202)].
        try await sendNoReply(
            transactionID: 204,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ]
        )
    }

    public func createFolder(at path: RemotePath, name: String) async throws {
        // transID 205, no-reply, [name(201), filePath(202)].
        try await sendNoReply(
            transactionID: 205,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ]
        )
    }

    public func fetchFileInfo(at path: RemotePath, name: String) async throws -> RemoteFileInfo {
        // transID 206, reply, [name(201), filePath(202)]. The reply
        // typically carries longType(205), longCreator(206), size(207),
        // creation/modification dates(208/209), comment(210). Date
        // payloads use the Hotline 8-byte format; `PacketField.date(_:)`
        // decodes via HotlineDate.
        let reply = try await sendExpectingReply(
            transactionID: 206,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ]
        )
        let typeFCC: FourCharCode = reply.first(.longFileType)
            .map { fourCharCode(from: $0.data) } ?? .file
        let creatorFCC: FourCharCode = reply.first(.longFileCreator)
            .map { fourCharCode(from: $0.data) } ?? .unknown
        let size = reply.uint32(.fileSize) ?? 0

        return RemoteFileInfo(
            file: RemoteFile(
                name: reply.string(.fileName, encoding: stringEncoding) ?? name,
                type: typeFCC,
                creator: creatorFCC,
                size: size,
                itemCount: 0
            ),
            creationDate: reply.date(.fileCreationDate),
            modificationDate: reply.date(.fileModificationDate),
            comment: reply.string(.fileComment, encoding: stringEncoding),
            dataForkSize: size,
            resourceForkSize: 0
        )
    }

    public func updateFileMetadata(
        at path: RemotePath,
        name: String,
        change: FileMetadataChange
    ) async throws {
        // transID 207, no-reply.
        //   .rename  → 211 carries the new name (per HEClient.m line 2186).
        //   .comment → 210 carries the new comment.
        var fields: [PacketField] = [
            .string(.fileName, name, encoding: stringEncoding)
        ]
        switch change {
        case .rename(let newName):
            fields.append(.string(.fileRename, newName, encoding: stringEncoding))
        case .comment(let newComment):
            fields.append(.string(.fileComment, newComment, encoding: stringEncoding))
        }
        fields.append(.path(.filePath, path, encoding: stringEncoding))
        try await sendNoReply(transactionID: 207, fields: fields)
    }

    public func moveEntry(
        from sourcePath: RemotePath,
        name: String,
        to destinationPath: RemotePath
    ) async throws {
        // transID 208, no-reply, [name(201), filePath(202), destPath(212)].
        try await sendNoReply(
            transactionID: 208,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, sourcePath, encoding: stringEncoding),
                .path(.destinationPath, destinationPath, encoding: stringEncoding)
            ]
        )
    }

    public func makeAlias(
        from sourcePath: RemotePath,
        name: String,
        to destinationPath: RemotePath
    ) async throws {
        // transID 209, no-reply, [name(201), filePath(202), destPath(212)].
        try await sendNoReply(
            transactionID: 209,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, sourcePath, encoding: stringEncoding),
                .path(.destinationPath, destinationPath, encoding: stringEncoding)
            ]
        )
    }

    // MARK: - Transfers (TODO)
    //
    // Hotline file transfers happen on a separate TCP stream the server
    // opens on demand; the reply to startDownload/startUpload contains
    // a transferID and total size, and the client then dials the server
    // again on the transfer port to read/write the actual bytes. That
    // side-channel needs its own actor; the request/reply parts below
    // would just hand back a TransferHandle with no live data behind it.
    // Leaving as notImplemented until the side-channel actor exists.

    public func startDownload(
        at path: RemotePath,
        name: String,
        dataForkOffset: UInt32,
        resourceForkOffset: UInt32
    ) async throws -> TransferHandle {
        // Control channel: transID 202 — downloadFile.
        // Attach the 74-byte resume blob (objID 203) only when at least
        // one fork has an offset > 0 — bare downloads omit the field
        // entirely, matching HEClient.m line 1597.
        var fields: [PacketField] = [
            .string(.fileName, name, encoding: stringEncoding),
            .path(.filePath, path, encoding: stringEncoding)
        ]
        let resume = ResumeInfo(
            dataForkOffset: dataForkOffset,
            resourceForkOffset: resourceForkOffset
        )
        if !resume.isFresh {
            fields.append(PacketField(
                key: .fileResumeInfo,
                data: ResumeInfoCodec.encode(resume)
            ))
        }
        let reply = try await sendExpectingReply(
            transactionID: 202,
            fields: fields
        )
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }
        let totalSize = reply.uint32(.transferSize) ?? 0

        let actor = try await openSideChannel(transferID: transferID, totalSize: UInt64(totalSize))
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(totalSize))
    }

    public func startFolderDownload(at path: RemotePath, name: String) async throws -> TransferHandle {
        // Control channel: transID 210 — downloadFolder.
        // Fields per HEClient.m line 1700+: fileName(201), filePath(202).
        let reply = try await sendExpectingReply(
            transactionID: 210,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ]
        )
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }
        let totalSize = reply.uint32(.transferSize) ?? 0

        // Open the side channel with the 18-byte folder-download
        // handshake. Streaming the per-item file payloads is not yet
        // implemented — the bytes are arriving on the connection but
        // we don't have a parser for the interleaved item-header /
        // FILP / INFO / DATA stream yet (HETransferThread.m line 245+).
        // The caller can already iterate `downloadStream(for:)` to see
        // the raw bytes if they want to roll their own parser.
        let actor = try await openFolderSideChannel(
            transferID: transferID,
            totalSize: UInt64(totalSize),
            isDownload: true
        )
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(totalSize))
    }

    public func startUpload(at path: RemotePath, name: String, size: UInt32, resume: Bool) async throws -> TransferHandle {
        // Control channel: transID 203 — uploadFile.
        // Fields per HEClient.m line 1771+:
        //   filePath(202), transferSize(108)=size, fileName(201), [optional resume flag]
        var fields: [PacketField] = [
            .path(.filePath, path, encoding: stringEncoding),
            .uint32(.transferSize, size),
            .string(.fileName, name, encoding: stringEncoding)
        ]
        if resume {
            fields.append(.uint16(.parameter, 1))
        }
        let reply = try await sendExpectingReply(transactionID: 203, fields: fields)
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }

        let actor = try await openSideChannel(transferID: transferID, totalSize: UInt64(size))
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(size))
    }

    public func sendUpload(
        _ content: Data,
        for handle: TransferHandle,
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        progress: (@Sendable (UInt64) async -> Void)?
    ) async throws {
        guard let actor = activeTransfers[handle.transferID] else {
            throw HotlineError.notConnected
        }

        let nameBytes = fileName.data(using: stringEncoding, allowLossyConversion: true) ?? Data()
        let total = UploadFraming.totalSize(
            nameLength: nameBytes.count,
            dataLength: UInt32(content.count)
        )

        // Re-send the HTXF handshake with the now-known total size. The
        // server already saw the zero-size handshake from openSideChannel;
        // the original Heidrun also opens with `xFerSize=0` and the
        // server tolerates either flow. Be explicit anyway.
        try await actor.sendBytes(
            TransferHandshake.encode(transferID: handle.transferID, transferSize: total)
        )

        // FILP + INFO + DATA hdr, then data-fork bytes in chunks (so
        // progress fires mid-transfer), then MACR trailer.
        let prefix = UploadFraming.encodePrefix(
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            dataLength: UInt32(content.count),
            encoding: stringEncoding
        )
        try await actor.sendBytes(prefix)

        let chunkSize = 64 * 1024
        var offset = 0
        var sent: UInt64 = 0
        while offset < content.count {
            let end = min(offset + chunkSize, content.count)
            try await actor.sendBytes(content.subdata(in: offset..<end))
            sent &+= UInt64(end - offset)
            offset = end
            if let progress { await progress(sent) }
        }

        try await actor.sendBytes(UploadFraming.encodeSuffix())
        await actor.finishUpload()
        activeTransfers.removeValue(forKey: handle.transferID)
    }

    public func startFolderUpload(
        at path: RemotePath,
        name: String,
        size: UInt32,
        itemCount: UInt16,
        resume: Bool
    ) async throws -> TransferHandle {
        // Control channel: transID 213 — uploadFolder.
        // Fields per HEClient.m line 1860+:
        //   filePath(202), folderName(201), folderSize(108)=size,
        //   itemCount(220)=itemCount, optional folderResumeFlag(204)=1.
        var fields: [PacketField] = [
            .path(.filePath, path, encoding: stringEncoding),
            .string(.fileName, name, encoding: stringEncoding),
            .uint32(.transferSize, size),
            .uint16(.folderItemCount, itemCount)
        ]
        if resume {
            fields.append(.uint16(.folderResumeFlag, 1))
        }
        let reply = try await sendExpectingReply(transactionID: 213, fields: fields)
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID")
        }

        let actor = try await openFolderSideChannel(
            transferID: transferID,
            totalSize: UInt64(size),
            isDownload: false
        )
        activeTransfers[transferID] = actor
        return TransferHandle(transferID: transferID, totalSize: UInt64(size))
    }

    /// Drive the per-item handshake for a folder upload started with
    /// `startFolderUpload(...)`. Sub-directories appear as items with
    /// `isDirectory == true` and empty `data`; files carry the data
    /// fork (resource fork is sent empty).
    public func sendFolderUpload(
        _ items: [FolderUploadItem],
        for handle: TransferHandle,
        type: FourCharCode = .file,
        creator: FourCharCode = .unknown,
        creationDate: Date = Date(),
        modificationDate: Date = Date()
    ) async throws {
        guard let actor = activeTransfers[handle.transferID] else {
            throw HotlineError.notConnected
        }

        var first = true
        for item in items {
            if !first {
                // Server sends `3` between items meaning "ready for the
                // next one". Anything else means it has decided to stop
                // and we should bail out.
                let next = try await actor.receiveUInt16()
                guard next == FolderUploadFraming.readyForNextItem else {
                    throw HotlineError.malformedReply(reason: "unexpected folder sync \(next)")
                }
            }
            first = false

            // 1) Send the per-item header (path components + isDir flag).
            let header = FolderUploadFraming.encodeItemHeader(
                relativePath: item.relativePath,
                isDirectory: item.isDirectory,
                encoding: stringEncoding
            )
            try await actor.sendBytes(header)

            // 2) Server replies with what to do for this entry: 1 upload,
            //    2 resume, 3 skip.
            guard let action = FolderUploadFraming.ItemAction(rawValue: try await actor.receiveUInt16()) else {
                throw HotlineError.malformedReply(reason: "unknown folder item action")
            }

            switch action {
            case .skip:
                continue
            case .resume:
                // Server sends UInt16 length + N bytes of resume info.
                // We parse the data-fork offset and skip that many bytes
                // off the front of our payload (resource fork is always
                // empty in this implementation).
                let blobSize = try await actor.receiveUInt16()
                let blob = try await actor.receiveExactly(Int(blobSize))
                let info = ResumeInfoCodec.decode(blob) ?? ResumeInfo()
                try await sendItemPayload(
                    item: item,
                    on: actor,
                    type: type,
                    creator: creator,
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    dataForkOffset: info.dataForkOffset
                )
            case .upload:
                try await sendItemPayload(
                    item: item,
                    on: actor,
                    type: type,
                    creator: creator,
                    creationDate: creationDate,
                    modificationDate: modificationDate,
                    dataForkOffset: 0
                )
            }
        }

        await actor.finishUpload()
        activeTransfers.removeValue(forKey: handle.transferID)
    }

    private func sendItemPayload(
        item: FolderUploadItem,
        on actor: FileTransferActor,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        dataForkOffset: UInt32 = 0
    ) async throws {
        guard !item.isDirectory else { return }
        let fileName = item.relativePath.last ?? ""
        let nameBytes = fileName.data(using: stringEncoding, allowLossyConversion: true) ?? Data()

        // Skip the prefix the server already has on disk for resumes.
        let dataPayload: Data
        let offset = Int(dataForkOffset)
        if offset >= item.data.count {
            dataPayload = Data()
        } else if offset > 0 {
            dataPayload = item.data.suffix(from: item.data.startIndex + offset)
        } else {
            dataPayload = item.data
        }

        let total = UploadFraming.totalSize(
            nameLength: nameBytes.count,
            dataLength: UInt32(dataPayload.count)
        )

        // The server expects the per-item total size as a UInt32 before
        // the FILP block (HETransferThread.m line 904).
        var sizeBytes = Data()
        sizeBytes.appendBigEndian(total)
        try await actor.sendBytes(sizeBytes)

        let framed = UploadFraming.encode(
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            data: dataPayload,
            encoding: stringEncoding
        )
        try await actor.sendBytes(framed)
    }

    public func cancelTransfer(_ handle: TransferHandle) async throws {
        if let actor = activeTransfers.removeValue(forKey: handle.transferID) {
            await actor.cancel()
        }
    }

    public nonisolated func downloadStream(for handle: TransferHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                guard let actor = await self.transferActor(for: handle.transferID) else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                for try await chunk in actor.bytes() {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    /// Stream the contents of a folder download started with
    /// `startFolderDownload(...)`. Each element is one file or directory
    /// the server is sending; the data fork lives in `data`, while
    /// sub-directories arrive with `isDirectory == true` and empty data.
    ///
    /// Directories are ACK'd with action=3 (skip) and acted on locally;
    /// files are ACK'd with action=1 (download), or action=2 + an RFLT
    /// blob when `resumeProvider` says we already have a partial copy.
    /// In the resume case each item's `dataForkOffset` tells the caller
    /// where to write the incoming bytes.
    public nonisolated func folderDownloadStream(
        for handle: TransferHandle,
        resumeProvider: FolderDownloadResumeProvider? = nil
    ) -> AsyncThrowingStream<FolderDownloadItem, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                guard let actor = await self.transferActor(for: handle.transferID) else {
                    continuation.finish(throwing: HotlineError.notConnected)
                    return
                }
                let encoding = await self.stringEncoding
                await FolderDownloadDecoder.drive(
                    actor: actor,
                    encoding: encoding,
                    resumeProvider: resumeProvider,
                    continuation: continuation
                )
                continuation.finish()
                await self.discardTransfer(transferID: handle.transferID)
            }
        }
    }

    private func discardTransfer(transferID: UInt32) {
        if let actor = activeTransfers.removeValue(forKey: transferID) {
            Task { await actor.cancel() }
        }
    }

    // MARK: - Side-channel helpers

    private func transferActor(for transferID: UInt32) -> FileTransferActor? {
        activeTransfers[transferID]
    }

    /// Open a fresh TCP connection to the server's transfer port (control
    /// port + 1), perform the HTXF handshake, and hand back the actor
    /// that wraps the connection.
    private func openSideChannel(transferID: UInt32, totalSize: UInt64) async throws -> FileTransferActor {
        let host = NWEndpoint.Host(connectionSettings.address)
        guard let port = NWEndpoint.Port(rawValue: connectionSettings.port &+ 1) else {
            throw HotlineError.notConnected
        }
        let sideQueue = DispatchQueue(label: "Heidrun.transfer.\(transferID)")
        let sideConnection = NWConnection(host: host, port: port, using: .tcp)
        try await sideConnection.startAndWaitForReady(on: sideQueue)

        let actor = FileTransferActor(
            connection: sideConnection,
            queue: sideQueue,
            transferID: transferID,
            totalSize: totalSize
        )
        try await actor.sendHandshake(transferSize: 0)
        return actor
    }

    /// Same as `openSideChannel(...)` but sends one of the folder-flavour
    /// HTXF preambles instead of the regular 16-byte handshake.
    private func openFolderSideChannel(
        transferID: UInt32,
        totalSize: UInt64,
        isDownload: Bool
    ) async throws -> FileTransferActor {
        let host = NWEndpoint.Host(connectionSettings.address)
        guard let port = NWEndpoint.Port(rawValue: connectionSettings.port &+ 1) else {
            throw HotlineError.notConnected
        }
        let sideQueue = DispatchQueue(label: "Heidrun.transfer.\(transferID)")
        let sideConnection = NWConnection(host: host, port: port, using: .tcp)
        try await sideConnection.startAndWaitForReady(on: sideQueue)

        let actor = FileTransferActor(
            connection: sideConnection,
            queue: sideQueue,
            transferID: transferID,
            totalSize: totalSize
        )
        let handshake = isDownload
            ? TransferHandshake.encodeFolderDownload(transferID: transferID)
            : TransferHandshake.encodeFolderUpload(transferID: transferID)
        try await actor.sendBytes(handshake)
        return actor
    }

    // MARK: - Private helpers

    private nonisolated func fourCharCode(from data: Data) -> FourCharCode {
        let bytes = Array(data.prefix(4)) + Array(repeating: UInt8(0), count: max(0, 4 - data.count))
        return FourCharCode(bytes: (bytes[0], bytes[1], bytes[2], bytes[3]))
    }
}
