#if canImport(Network)
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
    /// Owns the read loop, dispatch, broadcaster, keepalive, send-with-
    /// reply correlation, and teardown. Both clients share the same
    /// engine type — previously this plumbing was duplicated per client
    /// and drifted (the NIO copy was missing `broadcaster.finish()`,
    /// breaking auto-reconnect on Linux).
    private nonisolated let engine: HotlineProtocolEngine
    /// Outbound string encoding. Flips from macOS Roman to UTF-8 after the
    /// login reply when the server echoes `CapabilityFlags.textEncoding`
    /// (fogWraith). Actor-isolated, written only in `login` after the reply
    /// is decoded — no race with concurrent sends.
    private(set) var stringEncoding: String.Encoding
    let connectionSettings: ConnectionSettings

    private var connectionSocket: UInt16 = 0
    private var protocolVersion: Int = 0
    private var serverVersion: Int = 0
    private var clientVersion: Int = 151
    /// `true` after the server echoed `.resourceForkSupport` on the TX
    /// 107 login reply. When set, single-file downloads ship the
    /// FILP/INFO/DATA/MACR envelope and carry the resource fork.
    public private(set) var serverSupportsResourceForks: Bool = false
    /// `true` after the server echoed `.capabilities` with the
    /// `.largeFiles` bit set on the 107 login reply. When set, transfers
    /// over 4 GiB use the 24-byte HTXF handshake + 64-bit size fields.
    public private(set) var largeFilesEnabled: Bool = false
    var activeTransfers: [UInt32: FileTransferActor] = [:]
    /// Resource-fork bytes recovered from a framed `downloadStream`
    /// after the FILP envelope has been decoded. Persists past the
    /// activeTransfers cleanup so the caller can `consumeResourceFork`
    /// once the stream has finished. Read-once semantics (the accessor
    /// removes the entry) keep this map bounded.
    var bufferedResourceForks: [UInt32: Data] = [:]

    /// How often the keepalive task sends a `sendPing()` (transID 500)
    /// after login. Re-exported from the engine so existing callers
    /// reading `HotlineNetworkClient.keepaliveInterval` keep working.
    public static let keepaliveInterval: Duration = HotlineProtocolEngine.keepaliveInterval

    // MARK: - HotlineClient surface

    nonisolated public var events: AsyncStream<HotlineEvent> {
        engine.events
    }

    public var connectionInfo: HotlineConnectionInfo {
        get async {
            // The engine owns `lastTaskNumber` and `publicChatSubject`,
            // so the two reads cross the actor boundary. Call sites
            // already use `await client.connectionInfo`; the only thing
            // that changes is the getter's internal shape.
            let lastTask = await engine.lastTaskNumber
            let subject = await engine.publicChatSubjectValue
            let privileges = await engine.selfPrivilegesValue
            return HotlineConnectionInfo(
                clientVersion: clientVersion,
                protocolVersion: protocolVersion,
                serverVersion: serverVersion,
                connectionSocket: connectionSocket,
                lastTaskNumber: lastTask,
                settings: connectionSettings,
                publicChatSubject: subject,
                privileges: privileges
            )
        }
    }

    // MARK: - Lifecycle

    /// Open a TCP connection, perform the Hotline magic-byte handshake,
    /// and return a ready-to-use client. The caller still has to call
    /// `login(...)` to get past the server's auth gate.
    public static func connect(
        settings: ConnectionSettings,
        stringEncoding: String.Encoding = .macOSRoman,
        trustEvaluator: CertificateTrustEvaluator? = nil,
        packetObserver: PacketObserver? = nil
    ) async throws -> HotlineNetworkClient {
        let host = NWEndpoint.Host(settings.address)
        guard let port = NWEndpoint.Port(rawValue: settings.port) else {
            throw HotlineError.notConnected
        }
        // TCP keepalive at the OS level catches dead networks (no FIN
        // ever arrives) that the application-level ping alone can miss.
        // The app-level `pingTask` covers the "server is up but not
        // talking" case; the OS keepalive covers "the wire went away".
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let queue = DispatchQueue(label: "Heidrun.HotlineNetworkClient")
        // `tls: nil` is plain TCP. For TLS we install a custom verify block
        // (`TLSTrustVerifier`) so a pinned self-signed cert is accepted and an
        // unknown one triggers the trust-on-first-use evaluator; a real CA cert
        // still validates through the system trust store inside that block.
        let acceptedBox = AcceptedFingerprintBox()
        let parameters: NWParameters
        if settings.useTLS {
            let tlsOptions = NWProtocolTLS.Options()
            TLSTrustVerifier.install(
                on: tlsOptions,
                host: settings.address,
                port: settings.port,
                pinned: settings.pinnedCertificateSHA256,
                evaluator: trustEvaluator,
                acceptedBox: acceptedBox,
                queue: queue)
            parameters = NWParameters(tls: tlsOptions, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        // Race the connect against an explicit 15s deadline. NWConnection's
        // `tcp.connectionTimeout` is documented but doesn't reliably flip
        // the connection to `.failed` for black-holed routes (firewall
        // silently dropping SYNs), so we time it out ourselves: cancel the
        // connection from the watchdog task and let the canceller surface
        // a `HotlineError.notConnected` to the host.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await connection.startAndWaitForReady(on: queue)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                connection.cancel()
                throw HotlineError.notConnected
            }
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                // A verify-block rejection fails the handshake without ever
                // recording an accepted fingerprint — surface that as the
                // clearer trust error rather than a generic network failure.
                if settings.useTLS, acceptedBox.value == nil {
                    throw HotlineError.certificateNotTrusted
                }
                throw error
            }
            group.cancelAll()
        }
        try await Self.performHandshake(on: connection)

        // Pin whatever the handshake accepted (the freshly-trusted fingerprint
        // on first use, or the existing pin) so the transfer side-channel
        // verifies strictly against it without prompting again.
        var effectiveSettings = settings
        if let accepted = acceptedBox.value {
            effectiveSettings.pinnedCertificateSHA256 = accepted
        }
        let transport = NWConnectionTransport(connection: connection)
        let engine = HotlineProtocolEngine(
            transport: transport,
            stringEncoding: stringEncoding,
            packetObserver: packetObserver
        )
        let client = HotlineNetworkClient(
            connection: connection,
            queue: queue,
            engine: engine,
            settings: effectiveSettings,
            stringEncoding: stringEncoding
        )
        await engine.start()
        return client
    }

    private init(
        connection: NWConnection,
        queue: DispatchQueue,
        engine: HotlineProtocolEngine,
        settings: ConnectionSettings,
        stringEncoding: String.Encoding
    ) {
        self.connection = connection
        self.queue = queue
        self.engine = engine
        self.connectionSettings = settings
        self.stringEncoding = stringEncoding
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

    // MARK: - Transaction helpers (thin forwarders to the engine)

    /// Send a transaction through the engine. Most ops call one of the
    /// two helpers below; the underscore-no-prefix `send` exists so the
    /// `HotlineClient` protocol conformance has the canonical shape.
    func send(
        transactionID: UInt16,
        fields: [PacketField],
        expectsReply: Bool
    ) async throws -> [PacketField] {
        try await engine.send(
            transactionID: transactionID,
            fields: fields,
            expectsReply: expectsReply
        )
    }

    @discardableResult
    func sendNoReply(transactionID: UInt16, fields: [PacketField]) async throws -> [PacketField] {
        try await engine.send(transactionID: transactionID, fields: fields, expectsReply: false)
    }

    @discardableResult
    func sendExpectingReply(transactionID: UInt16, fields: [PacketField]) async throws -> [PacketField] {
        try await engine.send(transactionID: transactionID, fields: fields, expectsReply: true)
    }

    // MARK: - Lifecycle ops

    public func disconnect() async {
        await engine.disconnect()
    }

    public func requestAttention(_ flags: AttentionFlags) async {
        // Host-side concept; nothing to send over the wire.
    }

    // MARK: - Authentication & presence

    public func sendPing() async throws {
        // 185Ping uses transID 500. Forwarded so callers reading
        // `client.sendPing()` keep working; the engine owns the
        // protocol-level send.
        try await engine.sendPing()
    }

    public func login(
        name: String, password: String, nickname: String,
        icon: UInt16, emoji: String? = nil
    ) async throws {
        // Option 2: the nickname rides IN the login packet. It's encoded
        // UTF-8 when we advertise CAPABILITY_TEXT_ENCODING (we always do,
        // since `.supported` includes it), else macOS Roman. The server
        // decodes the login nick as UTF-8 when the login caps include the
        // textEncoding bit. Login name/password stay obfuscated credentials.
        let loginNickEncoding: String.Encoding =
            CapabilityFlags.supported.contains(.textEncoding) ? .utf8 : stringEncoding
        var fields: [PacketField] = [
            .obfuscatedString(.login, name, encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: loginNickEncoding),
            .uint16(.icon, icon == 0 ? 1 : icon),
            .uint16(.clientVersion, UInt16(clientVersion)),
            .uint8(.resourceForkSupport, 1),
            .uint16(.capabilities, CapabilityFlags.supported.rawValue)
        ]
        if let emoji { fields.append(.string(.userEmoji, emoji, encoding: .utf8)) }
        let reply = try await sendExpectingReply(transactionID: 107, fields: fields)
        if let server = reply.uint16(.clientVersion) {
            self.serverVersion = Int(server)
        }
        // Servers that follow the original Hotline convention echo the
        // socket id they just allocated for us. Stash it so the host
        // can label its own messages and skip its own self-echoes.
        if let socket = reply.uint16(.socket) {
            self.connectionSocket = socket
        }
        // Capability negotiation (Heidrun extension 0xE002): the server
        // only echoes the field when it actually supports the framed
        // single-file download path. No echo = fall back to raw bytes.
        self.serverSupportsResourceForks = reply.uint8(.resourceForkSupport) == 1
        self.largeFilesEnabled = CapabilityFlags.negotiatedLargeFiles(echoed: reply.uint16(.capabilities))
        // Text-encoding negotiation (fogWraith CAPABILITY_TEXT_ENCODING):
        // flip subsequent outbound traffic to UTF-8 when the server echoes
        // the bit. The login nickname was already sent UTF-8 in the login
        // packet above; the engine flips its own inbound decode independently
        // on the same reply.
        if CapabilityFlags.negotiatedTextEncoding(echoed: reply.uint16(.capabilities)) {
            self.stringEncoding = .utf8
        }
        // Start the heartbeat now that the server has authenticated us.
        // Pre-login pings would either be ignored or treated as a
        // protocol violation depending on the server.
        await engine.startKeepalive()
    }

    public func agreeToAgreement(nickname: String, icon: UInt16, emoji: String? = nil) async throws {
        var fields: [PacketField] = [
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon),
            .uint8(.resourceForkSupport, 1)
        ]
        if let emoji { fields.append(.string(.userEmoji, emoji, encoding: .utf8)) }
        try await sendNoReply(transactionID: 121, fields: fields)
    }

    public func changeNickname(
        _ nickname: String, icon: UInt16, emoji: String? = nil, persist: Bool
    ) async throws {
        // Always send userEmoji on a profile change so the server can tell
        // "cleared" (empty string) from "set". Default "" clears.
        let fields: [PacketField] = [
            .string(.nickname, nickname, encoding: stringEncoding),
            .uint16(.icon, icon),
            .string(.userEmoji, emoji ?? "", encoding: .utf8)
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
            nickname: reply.string(.nickname, encoding: stringEncoding) ?? "",
            emoji: reply.string(.userEmoji, encoding: .utf8)
        )
        let accountLogin = Self.decodeLoginField(reply.first(.login), encoding: stringEncoding)
        let infoText = reply.string(.message, encoding: stringEncoding) ?? ""
        return UserInfo(user: user, accountLogin: accountLogin, infoText: infoText)
    }

    /// Decode the `login` (objID 105) field from a 303 reply. Server
    /// implementations disagree on whether to XOR-obfuscate this field
    /// here: the auth-side convention says obfuscated, but plenty of
    /// servers send it plain on the info reply. We sniff the byte
    /// distribution and pick the right decoder: a plain ASCII login is
    /// all low-bit bytes; an obfuscated one is all high-bit bytes
    /// (because XOR with 0xFF flips the top bit of ASCII). Empty bytes
    /// or a missing field both return "".
    static func decodeLoginField(
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
    
    // MARK: - Account administration

    public func createLogin(name: String, password: String, nickname: String, privileges: UserPrivileges) async throws {
        // transID 350, [login(105 obfusc), password(106 obfusc), nick(102), privs(110, 8 bytes)].
        // Real Hotline servers reply with an error when the login already exists, so we await
        // the reply so that server errors surface as thrown HotlineError values.
        let fields: [PacketField] = [
            .obfuscatedString(.login, name, encoding: stringEncoding),
            .obfuscatedString(.password, password, encoding: stringEncoding),
            .string(.nickname, nickname, encoding: stringEncoding),
            PacketField(key: .privileges, data: Data(privileges.bytes))
        ]
        try await sendExpectingReply(transactionID: 350, fields: fields)
    }

    public func deleteLogin(_ name: String) async throws {
        // transID 351, [login(105 obfusc)].
        // Real Hotline servers reply with an error when the login is not found, so we await
        // the reply so that server errors surface as thrown HotlineError values.
        try await sendExpectingReply(
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
        // transID 353. Real Hotline servers reply with an error when the login is not found,
        // so we await the reply so that server errors surface as thrown HotlineError values.
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
        try await sendExpectingReply(transactionID: 353, fields: fields)
    }

    // MARK: - File system

    public func listFiles(at path: RemotePath) async throws -> [RemoteFile] {
        // transID 200, reply, [filePath(202)].
        let reply = try await sendExpectingReply(
            transactionID: 200,
            fields: [.path(.filePath, path, encoding: stringEncoding)]
        )
        return FileListEntryCodec.decodeList(fields: Array(reply), encoding: stringEncoding)
    }

    public func deleteEntry(at path: RemotePath, name: String) async throws {
        // transID 204, [name(201), filePath(202)]. Awaits the reply so a
        // server-side rejection (e.g. permission denied) throws instead of
        // silently no-op'ing.
        try await sendExpectingReply(
            transactionID: 204,
            fields: [
                .string(.fileName, name, encoding: stringEncoding),
                .path(.filePath, path, encoding: stringEncoding)
            ]
        )
    }

    public func createFolder(at path: RemotePath, name: String) async throws {
        // transID 205, [name(201), filePath(202)]. Awaits the reply so a
        // permission-denied / failure throws instead of silently failing.
        try await sendExpectingReply(
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
                size: UInt64(size),
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
        // transID 208, [name(201), filePath(202), destPath(212)]. Awaits
        // the reply so a permission-denied / failure throws.
        try await sendExpectingReply(
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

/// Adapts `NWConnection` to the engine's transport surface. `NWConnection`
/// is a reference type managed by Network.framework; wrapping it in a
/// `Sendable` struct that holds the reference lets us hand it across actor
/// boundaries into the engine.
private struct NWConnectionTransport: HotlineTransport {
    let connection: NWConnection

    func send(_ data: Data) async throws {
        try await connection.sendAsync(data)
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        try await connection.receiveExactly(count)
    }

    func close() async {
        connection.cancel()
    }
}
#endif
