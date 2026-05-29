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
