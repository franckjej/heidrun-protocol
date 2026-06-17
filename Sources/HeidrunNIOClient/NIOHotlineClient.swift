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
    public static let keepaliveInterval: Duration = HotlineProtocolEngine.keepaliveInterval

    /// Owns the read loop, dispatch, broadcaster, keepalive, send-with-
    /// reply correlation, and teardown. Previously this client duplicated
    /// the Darwin one's plumbing and drifted (the missing
    /// `broadcaster.finish()` in NIO's tearDown was what broke auto-
    /// reconnect on Linux). One engine, one place to fix bugs.
    private nonisolated let engine: HotlineProtocolEngine
    private let stringEncoding: String.Encoding
    private let settings: ConnectionSettings

    private var connectionSocket: UInt16 = 0
    private var serverVersion: Int = 0
    /// `true` after the server echoed `.resourceForkSupport` on TX 107.
    /// When set, single-file downloads ship the FILP envelope.
    public private(set) var serverSupportsResourceForks: Bool = false

    private init(engine: HotlineProtocolEngine, settings: ConnectionSettings,
                 stringEncoding: String.Encoding) {
        self.engine = engine
        self.settings = settings
        self.stringEncoding = stringEncoding
    }

    public nonisolated var events: AsyncStream<HotlineEvent> { engine.events }

    public var connectionInfo: HotlineConnectionInfo {
        get async {
            let lastTask = await engine.lastTaskNumber
            let privileges = await engine.selfPrivilegesValue
            return HotlineConnectionInfo(
                clientVersion: 151, protocolVersion: 2, serverVersion: serverVersion,
                connectionSocket: connectionSocket, lastTaskNumber: lastTask,
                settings: settings, privileges: privileges
            )
        }
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
        let transport = NIOTransport(channel: channel, reader: reader)
        // Drain the 12-byte handshake reply over the transport BEFORE
        // the engine starts owning the wire — pre-handshake bytes
        // aren't framed as Hotline packets and would crash the read
        // loop's decoder.
        try await performHandshake(over: transport)
        let engine = HotlineProtocolEngine(
            transport: transport,
            stringEncoding: stringEncoding,
            packetObserver: packetObserver
        )
        let client = NIOHotlineClient(engine: engine, settings: settings, stringEncoding: stringEncoding)
        await engine.start()
        // NIO starts keepalive at connect time (pre-login). The Darwin
        // client only starts it post-login. Preserving the existing per-
        // client behaviour so a server that tolerated NIO's pre-login
        // pings keeps tolerating them.
        await engine.startKeepalive()
        return client
    }

    private static func performHandshake(over transport: NIOTransport) async throws {
        // client → server "TRTPHOTL\0\1\0\2" (12 bytes); server → "TRTP" + UInt32 (8).
        let magic: [UInt8] = [0x54, 0x52, 0x54, 0x50, 0x48, 0x4F, 0x54, 0x4C, 0x00, 0x01, 0x00, 0x02]
        try await transport.send(Data(magic))
        let reply = try await transport.receiveExactly(8)
        guard reply.prefix(4) == Data([0x54, 0x52, 0x54, 0x50]) else {
            throw HotlineError.malformedReply(reason: "bad server magic")
        }
    }

    // MARK: Transaction helpers (forwarders into the engine)

    @discardableResult
    private func send(transactionID: UInt16, fields: [PacketField], expectsReply: Bool) async throws -> [PacketField] {
        try await engine.send(transactionID: transactionID, fields: fields, expectsReply: expectsReply)
    }

    // MARK: Public operations (bot-sufficient)

    public func login(name: String, password: String, nickname: String,
                      icon: UInt16, emoji: String?) async throws {
        var fields: [PacketField] = [
            .obfuscatedString(.login, name, encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon == 0 ? 1 : icon),
            .uint16(.clientVersion, 151),
            .uint8(.resourceForkSupport, 1)
        ]
        if let emoji { fields.append(.string(.userEmoji, emoji, encoding: .utf8)) }
        let reply = try await send(transactionID: 107, fields: fields, expectsReply: true)
        if let server = reply.uint16(.clientVersion) { serverVersion = Int(server) }
        if let socket = reply.uint16(.socket) { connectionSocket = socket }
        // Capability negotiation (Heidrun extension 0xE002).
        serverSupportsResourceForks = reply.uint8(.resourceForkSupport) == 1
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
            .uint16(.icon, icon),
            .uint8(.resourceForkSupport, 1)
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

    /// Delete a file or (recursively) a folder at `(path, name)`. TX 204,
    /// no-reply, `[fileName(201), filePath(202)]`. Mirrors
    /// `HotlineNetworkClient.deleteEntry`.
    public func deleteEntry(at path: RemotePath, name: String) async throws {
        try await send(
            transactionID: 204,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ],
            expectsReply: true
        )
    }

    /// Create a folder named `name` inside `path`. TX 205,
    /// `[fileName(201), filePath(202)]`. Awaits the reply so a
    /// permission-denied / failure throws. Mirrors
    /// `HotlineNetworkClient.createFolder`.
    public func createFolder(at path: RemotePath, name: String) async throws {
        try await send(
            transactionID: 205,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ],
            expectsReply: true
        )
    }

    /// Move `name` from `sourcePath` into `destinationPath`. TX 208,
    /// no-reply, `[fileName(201), filePath(202), destinationPath(212)]`.
    /// Mirrors `HotlineNetworkClient.moveEntry`.
    public func moveEntry(
        from sourcePath: RemotePath,
        name: String,
        to destinationPath: RemotePath
    ) async throws {
        try await send(
            transactionID: 208,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, sourcePath, encoding: stringEncoding),
                .path(.destinationPath, destinationPath, encoding: stringEncoding)
            ],
            expectsReply: true
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

    // MARK: File transfers (HTXF side channel)

    /// Download a file. Sends TX 202, pulls `transferID` +
    /// `transferSize` from the reply, opens an HTXF side channel on
    /// `settings.port + 1`, and streams the data fork to
    /// `destination`. Hotline downloads are data-fork only on this
    /// path — the side channel doesn't carry the FILP envelope, just
    /// the bytes. Overwrites `destination` if it exists.
    public func downloadFile(
        at path: RemotePath,
        name: String,
        to destination: URL,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws {
        let reply = try await send(
            transactionID: 202,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ],
            expectsReply: true
        )
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID on TX 202 reply")
        }
        let totalSize = reply.uint32(.transferSize) ?? 0
        try await NIOTransferConnection.download(
            host: settings.address,
            transferPort: settings.port + 1,
            transferID: transferID,
            totalSize: totalSize,
            to: destination,
            progress: progress
        )
    }

    /// Upload a local file. Sends TX 203 with the announced size,
    /// pulls `transferID` from the reply, opens an HTXF side channel,
    /// and streams the FILP envelope + data fork from disk so a
    /// multi-GB upload doesn't sit in memory. Pass `resourceFork` when
    /// the file has a resource fork to ship in the MACR trailer (left
    /// empty by default — most modern uploads are data-fork only).
    public func uploadFile(
        at path: RemotePath,
        name: String,
        from source: URL,
        type: HeidrunCore.FourCharCode,
        creator: HeidrunCore.FourCharCode,
        resourceFork: Data = Data(),
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let fileSize = UInt32(clamping: (attributes[.size] as? Int) ?? 0)
        let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
        let creationDate = (attributes[.creationDate] as? Date) ?? modificationDate
        let reply = try await send(
            transactionID: 203,
            fields: [
                .path(.filePath, path, encoding: stringEncoding),
                .uint32(.transferSize, fileSize),
                .string(.fileName, name, encoding: stringEncoding)
            ],
            expectsReply: true
        )
        guard let transferID = reply.uint32(.transferID) else {
            throw HotlineError.malformedReply(reason: "missing transferID on TX 203 reply")
        }
        try await NIOTransferConnection.upload(
            host: settings.address,
            transferPort: settings.port + 1,
            transferID: transferID,
            source: source,
            fileSize: fileSize,
            fileName: name,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            resourceFork: resourceFork,
            encoding: stringEncoding,
            progress: progress
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
            // Await the reply so a denial (no postNews) surfaces as an error.
            expectsReply: true
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

    // MARK: - Admin

    public func kick(socket: UInt16, ban: Bool) async throws {
        var fields: [PacketField] = [.uint16(.socket, socket)]
        if ban { fields.append(.uint16(.banFlag, 1)) }
        try await send(transactionID: 110, fields: fields, expectsReply: true)
    }

    public func broadcast(_ message: String) async throws {
        try await send(
            transactionID: 355,
            fields: [.string(.message, message, encoding: stringEncoding)],
            expectsReply: true
        )
    }

    public func createLogin(
        name: String, password: String, nickname: String, privileges: UserPrivileges
    ) async throws {
        let fields: [PacketField] = [
            .obfuscatedString(.login, name, encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: stringEncoding),
            PacketField(key: .privileges, data: Data(privileges.bytes))
        ]
        try await send(transactionID: 350, fields: fields, expectsReply: true)
    }

    public func deleteLogin(_ name: String) async throws {
        try await send(
            transactionID: 351,
            fields: [.obfuscatedString(.login, name, encoding: stringEncoding)],
            expectsReply: true
        )
    }

    // MARK: Lifecycle (forwarded to the engine)

    public func disconnect() async {
        await engine.disconnect()
    }
}

/// Adapts a SwiftNIO `Channel` plus the inbound-byte `ByteAccumulator`
/// to the engine's transport surface. `@unchecked Sendable` because
/// `ByteAccumulator` is documented single-consumer (only the engine's
/// read loop calls `receiveExactly`, never concurrently); the channel
/// is itself Sendable by NIO's design.
struct NIOTransport: HotlineTransport, @unchecked Sendable {
    let channel: Channel
    let reader: ByteAccumulator

    func send(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer)
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        try await reader.receiveExactly(count)
    }

    func close() async {
        try? await channel.close()
    }
}
