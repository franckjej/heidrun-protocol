import Foundation
import NIOCore
import NIOPosix
import HeidrunCore

/// Cross-platform (Linux + macOS) Hotline client on SwiftNIO. Reuses
/// HeidrunCore's codecs + EventBroadcaster; only the transport is new. A
/// focused client for the bot (full HotlineClient conformance is future HX
/// work). The read loop / dispatch / transaction encoders mirror the Darwin
/// HotlineNetworkClient.
public actor NIOHotlineClient {
    public static let keepaliveInterval: Duration = .seconds(30)

    private let channel: Channel
    private let reader: ByteAccumulator
    private let broadcaster = EventBroadcaster()
    private let stringEncoding: String.Encoding
    private let settings: ConnectionSettings
    /// Optional developer-console hook. See `PacketObserver` for
    /// payload semantics. Same shape as on `HotlineNetworkClient`.
    private let packetObserver: PacketObserver?

    private var nextTaskNumber: UInt32 = 1
    private var pendingReplies: [UInt32: CheckedContinuation<[PacketField], Error>] = [:]
    private var connectionSocket: UInt16 = 0
    private var serverVersion: Int = 0
    private var readerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var torn = false

    private init(channel: Channel, reader: ByteAccumulator,
                 settings: ConnectionSettings, stringEncoding: String.Encoding,
                 packetObserver: PacketObserver? = nil) {
        self.channel = channel
        self.reader = reader
        self.settings = settings
        self.stringEncoding = stringEncoding
        self.packetObserver = packetObserver
    }

    public nonisolated var events: AsyncStream<HotlineEvent> { broadcaster.makeStream() }

    public var connectionInfo: HotlineConnectionInfo {
        HotlineConnectionInfo(
            clientVersion: 151, protocolVersion: 2, serverVersion: serverVersion,
            connectionSocket: connectionSocket, lastTaskNumber: nextTaskNumber &- 1,
            settings: settings
        )
    }

    // MARK: Connect + handshake

    public static func connect(
        settings: ConnectionSettings,
        stringEncoding: String.Encoding = .macOSRoman,
        packetObserver: PacketObserver? = nil
    ) async throws -> NIOHotlineClient {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let bootstrap = ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHandler(InboundByteBridge(continuation: continuation))
            }
        let channel = try await bootstrap.connect(host: settings.address, port: Int(settings.port)).get()
        let reader = ByteAccumulator(stream: stream)
        let client = NIOHotlineClient(channel: channel, reader: reader,
                                      settings: settings, stringEncoding: stringEncoding,
                                      packetObserver: packetObserver)
        try await client.performHandshake()
        await client.startReader()
        await client.startKeepalive()
        return client
    }

    private func performHandshake() async throws {
        // client → server "TRTPHOTL\0\1\0\2" (12 bytes); server → "TRTP" + UInt32 (8).
        let magic: [UInt8] = [0x54, 0x52, 0x54, 0x50, 0x48, 0x4F, 0x54, 0x4C, 0x00, 0x01, 0x00, 0x02]
        try await send(Data(magic))
        let reply = try await reader.receiveExactly(8)
        guard reply.prefix(4) == Data([0x54, 0x52, 0x54, 0x50]) else {
            throw HotlineError.malformedReply(reason: "bad server magic")
        }
    }

    private func send(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer)
    }

    // MARK: Read loop + dispatch (ported from HotlineNetworkClient)

    private func startReader() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in await self?.runReadLoop() }
    }

    private func runReadLoop() async {
        while !torn {
            do {
                let headerData = try await reader.receiveExactly(PacketHeader.byteCount)
                guard let header = PacketHeader(decoding: headerData) else {
                    throw HotlineError.malformedReply(reason: "short header")
                }
                let body = header.dataLength > 0
                    ? try await reader.receiveExactly(Int(header.dataLength))
                    : Data()
                dispatch(header: header, body: body)
            } catch {
                tearDown(with: error)
                return
            }
        }
    }

    private func dispatch(header: PacketHeader, body: Data) {
        let fields = PacketCodec.decodeBody(body)
        // Developer-console hook: every inbound packet, including
        // replies and any TX IDs we don't recognise as either
        // requests-we-sent or info-pushes. Lets a UI flag dialect
        // traffic.
        packetObserver?.handle(.inbound, header, fields)

        // Server-pushed ping (classID=0 request, TX 500) needs an
        // explicit reply or the server reaps us after its keepalive
        // window. Same protocol behaviour as the Darwin transport.
        if header.classID == 0, header.transactionID == 500 {
            sendInbandPingReply(taskNumber: header.taskNumber)
            return
        }

        if let continuation = pendingReplies.removeValue(forKey: header.taskNumber) {
            if header.errorID != 0 {
                continuation.resume(throwing: HotlineError.serverError(
                    id: header.errorID, message: fields.string(.errorMessage, encoding: stringEncoding)))
            } else {
                continuation.resume(returning: fields)
            }
            return
        }

        guard let info = InfoTransaction(rawValue: header.transactionID) else { return }
        switch info {
        case .relayChat:
            let text = fields.string(.message, encoding: stringEncoding) ?? ""
            let chat: ChatID? = fields.first(.chatReference).map { ChatID(data: $0.data) }
            let isAction = (fields.uint16(.parameter) ?? 0) != 0
            broadcaster.yield(.chatReceived(chat: chat, message: text, isAction: isAction))
        case .disconnected:
            let reason = fields.string(.errorMessage, encoding: stringEncoding)
                ?? fields.string(.message, encoding: stringEncoding)
            broadcaster.yield(.disconnected(reason: reason))
        case .userChanged:
            broadcaster.yield(.userChanged(user: User(
                socket: fields.uint16(.socket) ?? 0,
                icon: fields.uint16(.icon) ?? 0,
                status: UserStatus(rawValue: fields.uint16(.status) ?? 0),
                privileges: [],
                nickname: fields.string(.nickname, encoding: stringEncoding) ?? "",
                emoji: fields.string(.userEmoji, encoding: .utf8))))
        case .userLeft:
            broadcaster.yield(.userLeft(socket: fields.uint16(.socket) ?? 0))
        case .message:
            broadcaster.yield(.messageReceived(
                from: fields.uint16(.socket) ?? 0,
                message: fields.string(.message, encoding: stringEncoding) ?? ""))
        case .broadcast:
            broadcaster.yield(.broadcastReceived(
                message: fields.string(.message, encoding: stringEncoding) ?? ""))
        default:
            break   // other pushes (news/private-chat/transfers) — added with HX
        }
    }

    // MARK: Transaction helpers (ported)

    private func nextTaskID() -> UInt32 { defer { nextTaskNumber &+= 1 }; return nextTaskNumber }

    /// Acknowledge a server-pushed ping. Mirrors HotlineNetworkClient
    /// — fire-and-forget reply with classID=1, txID=0, no body.
    private func sendInbandPingReply(taskNumber: UInt32) {
        let replyPacket = PacketCodec.encode(
            classID: 1,
            transactionID: 0,
            taskNumber: taskNumber,
            fields: []
        )
        Task { [weak self] in
            try? await self?.send(replyPacket)
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

    @discardableResult
    private func send(transactionID: UInt16, fields: [PacketField], expectsReply: Bool) async throws -> [PacketField] {
        let taskNumber = nextTaskID()
        let packet = PacketCodec.encode(classID: 0, transactionID: transactionID,
                                        taskNumber: taskNumber, fields: fields)
        if let packetObserver {
            // Header constructed from arguments since `PacketCodec.encode`
            // doesn't return one. lengths populated for completeness.
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
                Task {
                    do { try await send(packet) }
                    catch {
                        if let resumer = pendingReplies.removeValue(forKey: taskNumber) {
                            resumer.resume(throwing: error)
                        }
                    }
                }
            }
        } else {
            try await send(packet)
            return []
        }
    }

    // MARK: Public operations (bot-sufficient)

    public func login(name: String, password: String, nickname: String,
                      icon: UInt16, emoji: String?) async throws {
        var fields: [PacketField] = [
            .obfuscatedString(.login, name, encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon == 0 ? 1 : icon),
            .uint16(.clientVersion, 151)
        ]
        if let emoji { fields.append(.string(.userEmoji, emoji, encoding: .utf8)) }
        let reply = try await send(transactionID: 107, fields: fields, expectsReply: true)
        if let server = reply.uint16(.clientVersion) { serverVersion = Int(server) }
        if let socket = reply.uint16(.socket) { connectionSocket = socket }
    }

    public func sendChat(_ message: String, in chat: ChatID?, isAction: Bool) async throws {
        var fields: [PacketField] = [.string(.message, message, encoding: stringEncoding)]
        if let chat { fields.append(PacketField(key: .chatReference, data: chat.data)) }
        fields.append(.uint16(.parameter, isAction ? 1 : 0))
        try await send(transactionID: 105, fields: fields, expectsReply: false)
    }

    public func changeNickname(_ nickname: String, icon: UInt16, emoji: String?) async throws {
        try await send(transactionID: 304, fields: [
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon),
            .string(.userEmoji, emoji ?? "", encoding: .utf8)
        ], expectsReply: false)
    }

    public func fetchUserList() async throws -> [User] {
        let reply = try await send(transactionID: 300, fields: [], expectsReply: true)
        return reply
            .filter { $0.key == HotlineObjectKey.userListEntry.rawValue }
            .compactMap { UserListEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    public func sendPing() async throws {
        try await send(transactionID: 500, fields: [], expectsReply: false)
    }

    public func fetchUserInfo(socket: UInt16) async throws -> UserInfo {
        let reply = try await send(
            transactionID: 303,
            fields: [.uint16(.socket, socket)],
            expectsReply: true
        )
        let user = User(
            socket: socket,
            icon: reply.uint16(.icon) ?? 0,
            status: UserStatus(rawValue: reply.uint16(.status) ?? 0),
            privileges: [],
            nickname: reply.string(.nickname, encoding: stringEncoding) ?? "",
            emoji: reply.string(.userEmoji, encoding: .utf8)
        )
        let accountLogin = Self.decodeLoginField(reply.first(.login), encoding: stringEncoding)
        let infoText = reply.string(.message, encoding: stringEncoding) ?? ""
        return UserInfo(user: user, accountLogin: accountLogin, infoText: infoText)
    }

    public func sendPrivateMessage(_ message: String, to socket: UInt16) async throws {
        try await send(
            transactionID: 108,
            fields: [
                .uint16(.socket, socket),
                .string(.message, message, encoding: stringEncoding)
            ],
            expectsReply: true
        )
    }

    /// Acknowledge a server-pushed agreement. Required to clear the
    /// "must agree" gate some servers put between login and chat —
    /// without this the connection stays in limbo. TX 121, no reply.
    public func agreeToAgreement(nickname: String, icon: UInt16, emoji: String? = nil) async throws {
        var fields: [PacketField] = [
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon)
        ]
        if let emoji { fields.append(.string(.userEmoji, emoji, encoding: .utf8)) }
        try await send(transactionID: 121, fields: fields, expectsReply: false)
    }

    /// List directory entries at the given remote path. Root = empty
    /// `RemotePath`. TX 200 reply contains zero or more
    /// `.fileListEntry` blobs, each decoded by `FileListEntryCodec`.
    public func listFiles(at path: RemotePath) async throws -> [RemoteFile] {
        let reply = try await send(
            transactionID: 200,
            fields: [.path(.filePath, path, encoding: stringEncoding)],
            expectsReply: true
        )
        return reply
            .filter { $0.key == HotlineObjectKey.fileListEntry.rawValue }
            .compactMap { FileListEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    /// Fetch metadata for one file at `(path, name)`. TX 206 reply
    /// carries longFileType / longFileCreator / size / creation +
    /// modification dates / optional comment. Dates use the Hotline
    /// 1904-epoch encoding decoded by `PacketField.date(_:)`.
    public func fetchFileInfo(at path: RemotePath, name: String) async throws -> RemoteFileInfo {
        let reply = try await send(
            transactionID: 206,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ],
            expectsReply: true
        )
        let typeFCC: HeidrunCore.FourCharCode = reply.first(.longFileType)
            .map { Self.fourCharCode(from: $0.data) } ?? .file
        let creatorFCC: HeidrunCore.FourCharCode = reply.first(.longFileCreator)
            .map { Self.fourCharCode(from: $0.data) } ?? .unknown
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

    /// Big-endian 4-byte → `FourCharCode`. Mirrors the private helper
    /// on `HotlineNetworkClient`. Pads with NUL when the field is
    /// short (some servers send fewer bytes for `.unknown` creators).
    private static func fourCharCode(from data: Data) -> HeidrunCore.FourCharCode {
        let bytes = Array(data.prefix(4)) + Array(repeating: UInt8(0), count: max(0, 4 - data.count))
        return HeidrunCore.FourCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// Fetch the plain (bulletin-board) news feed. TX 101 reply
    /// carries the whole feed as a single `.message` field.
    public func fetchNewsFeed() async throws -> String {
        let reply = try await send(transactionID: 101, fields: [], expectsReply: true)
        return reply.string(.message, encoding: stringEncoding) ?? ""
    }

    /// Append one entry to the plain news feed. TX 103 (postNewNews),
    /// the server inserts it at the top and pushes `.newsPosted` to
    /// every connected client (already wired into the broadcaster).
    public func postPlainNews(_ text: String) async throws {
        try await send(
            transactionID: 103,
            fields: [.string(.message, text, encoding: stringEncoding)],
            expectsReply: true
        )
    }

    // MARK: Threaded news (Hotline 1.5+ servers)

    /// List the news bundles (folders + categories) at the given
    /// `newsPath`. Root = empty path. TX 370 reply carries 0+
    /// `.newsBundleEntry` blobs decoded by `NewsBundleEntryCodec`.
    public func fetchNewsBundles(at path: RemotePath) async throws -> [NewsBundle] {
        let reply = try await send(
            transactionID: 370,
            fields: [.path(.newsPath, path, encoding: stringEncoding)],
            expectsReply: true
        )
        return reply
            .filter { $0.key == HotlineObjectKey.newsBundleEntry.rawValue }
            .compactMap { NewsBundleEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    /// List the threads inside a category at the given `newsPath`. TX
    /// 371 reply carries a single `.newsThreadList` blob decoded by
    /// `NewsThreadListCodec` into a flat array of threads (the
    /// parent-id field is what makes the tree structure).
    public func fetchNewsThreads(at path: RemotePath) async throws -> [NewsThread] {
        let reply = try await send(
            transactionID: 371,
            fields: [.path(.newsPath, path, encoding: stringEncoding)],
            expectsReply: true
        )
        guard let blob = reply.first(.newsThreadList) else { return [] }
        return NewsThreadListCodec.decode(blob.data, encoding: stringEncoding)
    }

    /// Post a new threaded-news article (top-level when `parentThreadID
    /// == 0`, otherwise a reply to that article). TX 410, six fields:
    /// `newsPath(325)`, `articleID(326)` carrying the parent id per
    /// Hotline 1.5 spec, `title(328)`, `articleFlags(334)` zero,
    /// `type(327)`, `body(333)`. Server replies success/error but the
    /// Darwin client uses `sendNoReply` here so we mirror that — the
    /// reply is informational only and the caller treats post as
    /// fire-and-forget; if it really failed (e.g. permission) the
    /// next `fetchNewsThreads` won't see the post.
    public func postNewsThread(
        at path: RemotePath,
        parentThreadID: UInt16,
        title: String,
        type: String,
        body: String
    ) async throws {
        try await send(
            transactionID: 410,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, parentThreadID),
                .string(.newsTitle, title, encoding: stringEncoding),
                .uint16(.newsArticleFlags, 0),
                .string(.newsType, type, encoding: stringEncoding),
                .string(.newsData, body, encoding: stringEncoding)
            ],
            expectsReply: false
        )
    }

    /// Fetch a single thread's body. TX 400 takes the category path,
    /// the article id, and the requested element MIME type. Reply
    /// carries parent/post-date + a single thread element (title +
    /// author + body). Mirrors the Darwin-side decoder so the body
    /// pane on any UI gets the same shape.
    public func fetchNewsThread(at path: RemotePath, threadID: UInt16, type: String) async throws -> NewsThread {
        let reply = try await send(
            transactionID: 400,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, threadID),
                .string(.newsType, type, encoding: stringEncoding)
            ],
            expectsReply: true
        )
        let parentID = reply.uint16(.newsParentThread) ?? 0
        let postDate = reply.date(.newsDate) ?? Date.distantPast
        var elements: [ThreadElement] = []
        let elementTitle = reply.string(.newsTitle, encoding: stringEncoding)
        let elementBody = reply.string(.newsData, encoding: stringEncoding)
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
        return NewsThread(threadID: threadID, parentID: parentID, postDate: postDate, elements: elements)
    }

    /// Mirrors `HotlineNetworkClient.decodeLoginField` — the `login`
    /// field on a 303 reply may or may not be XOR-obfuscated depending
    /// on server flavour, so we sniff the high-bit distribution and
    /// pick the right decoder. Duplicated rather than shared to keep
    /// the cross-platform NIO module from depending on the Darwin
    /// Network/ folder.
    private static func decodeLoginField(
        _ field: PacketField?,
        encoding: String.Encoding
    ) -> String {
        guard let field, !field.data.isEmpty else { return "" }
        let highBitCount = field.data.reduce(0) { count, byte in
            byte >= 0x80 ? count + 1 : count
        }
        let looksObfuscated = highBitCount * 2 > field.data.count
        if looksObfuscated {
            var bytes = field.data
            for index in bytes.indices {
                bytes[index] = bytes[index] ^ 0xFF
            }
            return String(data: bytes, encoding: encoding) ?? ""
        }
        return String(data: field.data, encoding: encoding) ?? ""
    }

    // MARK: Keepalive + teardown

    private func startKeepalive() {
        guard pingTask == nil, !torn else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: NIOHotlineClient.keepaliveInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                do { try await self.sendPing() } catch { await self.failAndClose(error); return }
            }
        }
    }

    public func disconnect() async {
        tearDown(with: HotlineError.cancelled)
    }

    private func failAndClose(_ error: Error) { tearDown(with: error) }

    private func tearDown(with error: Error) {
        guard !torn else { return }
        torn = true
        pingTask?.cancel(); pingTask = nil
        readerTask?.cancel(); readerTask = nil
        let pending = pendingReplies
        pendingReplies.removeAll()
        for (_, cont) in pending { cont.resume(throwing: error) }
        channel.close(promise: nil)
        broadcaster.yield(.disconnected(reason: nil))
    }
}
