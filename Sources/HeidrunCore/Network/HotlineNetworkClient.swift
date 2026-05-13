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
    let stringEncoding: String.Encoding
    let connectionSettings: ConnectionSettings

    private var nextTaskNumber: UInt32 = 1
    private var pendingReplies: [UInt32: CheckedContinuation<[PacketField], Error>] = [:]
    private var connectionSocket: UInt16 = 0
    private var protocolVersion: Int = 0
    private var serverVersion: Int = 0
    private var clientVersion: Int = 151
    private var readerTask: Task<Void, Never>?
    private var torn = false
    var activeTransfers: [UInt32: FileTransferActor] = [:]

    // MARK: - HotlineClient surface

    nonisolated public var events: AsyncStream<HotlineEvent> {
        broadcaster.makeStream()
    }

    public var connectionInfo: HotlineConnectionInfo {
        HotlineConnectionInfo(
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            serverVersion: serverVersion,
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
    func sendExpectingReply(transactionID: UInt16, fields: [PacketField]) async throws -> [PacketField] {
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
            .obfuscatedString(.login, name, encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: stringEncoding),
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
            .obfuscatedString(.login, name, encoding: stringEncoding),
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

    public func fetchNewsBundles(at path: RemotePath) async throws -> [NewsBundle] {
        // transID 370. Reply contains 0+ newsBundleEntry(323) fields.
        let reply = try await sendExpectingReply(
            transactionID: 370,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
        return reply
            .filter { $0.key == HotlineObjectKey.newsBundleEntry.rawValue }
            .compactMap { NewsBundleEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    public func fetchNewsThreads(at path: RemotePath) async throws -> [NewsThread] {
        // transID 371. Reply carries a single newsThreadList(321) blob.
        let reply = try await sendExpectingReply(
            transactionID: 371,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
        guard let blob = reply.first(.newsThreadList) else { return [] }
        return NewsThreadListCodec.decode(blob.data, encoding: stringEncoding)
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
        let elementBody  = reply.string(.newsData, encoding: stringEncoding)
        if elementTitle != nil || elementBody != nil {
            let bodyBytes = reply.first(.newsData)?.data.count ?? 0
            elements.append(ThreadElement(
                title: elementTitle ?? "",
                author: reply.string(.newsAuthor, encoding: stringEncoding) ?? "",
                mimeType: reply.string(.newsType, encoding: stringEncoding) ?? ThreadElement.plainTextType,
                size: UInt16(clamping: bodyBytes),
                body: elementBody ?? ""
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

    // MARK: - Private helpers

    nonisolated private func fourCharCode(from data: Data) -> FourCharCode {
        let bytes = Array(data.prefix(4)) + Array(repeating: UInt8(0), count: max(0, 4 - data.count))
        return FourCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
