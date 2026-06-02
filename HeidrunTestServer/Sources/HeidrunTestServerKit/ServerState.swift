import Foundation
import Network
import HeidrunCore

/// One open private-chat room. Membership is just a set of sockets;
/// when the last member leaves the chat is dropped.
struct PrivateChat: Sendable {
    let id: UInt32
    var members: Set<UInt16>
    var subject: String = ""
}

/// Shared, mutable state across all connected clients.
///
/// Heidrun's test server is a single-process toy — one actor holds every
/// piece of mutable state and serialises access. Concurrent clients
/// drive the actor with await, no locks of our own.
public actor ServerState {
    /// Server version we advertise in the login reply. The client maps
    /// `< 151` → plain-only news UI, `>= 151` → threaded news UI.
    public let advertisedVersion: UInt16

    /// Cap the download side-channel at this many KB/s. `0` means
    /// unthrottled — the historical behaviour. Used by the CLI to slow
    /// loopback transfers down enough that the operator can `kill -9`
    /// the client mid-transfer for resume-flow smoke tests.
    public let downloadThrottleKBps: UInt32

    /// Agreement banner pushed to each client right after a successful
    /// login (transID 109). `nil` skips the push, mirroring servers that
    /// don't bother with one.
    public let agreement: String?

    /// Newest-first list of plain-news posts. `getNewsList` joins these
    /// with "\r" separators (Hotline convention).
    public private(set) var plainPosts: [String] = []

    /// Threaded-news fixture tree (folders/categories/posts).
    private(set) var threaded: [BundleNode]

    /// In-memory file system the file-transfer transactions read from
    /// and write to. The HTXF side channel keys into `pendingTransfers`
    /// to know what each connecting transfer port is for.
    public let vfs: VFS

    /// Admin-managed account roster. Consulted by login (107) and
    /// mutated by the admin transactions (350/351/352/353).
    public let accounts: AccountStore

    /// Side-channel transfers the control channel has authorised but
    /// the HTXF listener hasn't seen yet.
    private var pendingTransfers: [UInt32: PendingTransfer] = [:]

    /// Side-channel connections currently streaming a transfer. Tracked
    /// so trans=214 (cancelFileTransfer) can pull the plug — cancelling
    /// the NWConnection makes the listener's in-flight `sendAsync` /
    /// `receiveExactly` throw, the handler's `do { ... } catch { }`
    /// swallows the error and `connection.cancel()` runs cleanly. Keyed
    /// by the transfer id the client cited in the cancel transaction.
    private var activeTransferConnections: [UInt32: NWConnection] = [:]

    /// Monotonic transfer id counter. Shared across downloads/uploads.
    private var nextTransferID: UInt32 = 1

    /// Connected users, keyed by socket.
    private var users: [UInt16: User] = [:]

    /// Per-connection metadata the user list itself doesn't carry but
    /// the "get user info" reply (transID 303) renders into the profile
    /// dump: the login the peer authenticated as, the version number
    /// they sent in the login transaction, the IP:port we accepted them
    /// from, and the moment they finished logging in.
    public struct Session: Sendable, Hashable {
        public var login: String
        public var clientVersion: UInt16
        public var remoteHost: String
        public var loginAt: Date
        /// `true` when the client advertised the Heidrun
        /// `resourceForkSupport` extension on TX 107. Drives whether
        /// single-file downloads ship the FILP envelope.
        public var supportsResourceForks: Bool

        public init(
            login: String,
            clientVersion: UInt16,
            remoteHost: String,
            loginAt: Date,
            supportsResourceForks: Bool = false
        ) {
            self.login = login
            self.clientVersion = clientVersion
            self.remoteHost = remoteHost
            self.loginAt = loginAt
            self.supportsResourceForks = supportsResourceForks
        }
    }

    private var sessions: [UInt16: Session] = [:]

    /// Per-connection event sinks. When a client posts plain news, every
    /// connected user should see a `kInfoNewPost` push.
    private var pushSinks: [UInt16: @Sendable (Data) async -> Void] = [:]

    /// Per-connection close hooks. Calling the closure cancels the
    /// underlying `NWConnection`, which makes the owning Connection's
    /// read loop exit and run the normal disconnect teardown (broadcast
    /// transID 302, drop from private chats). Used by the kick handler.
    private var closeSinks: [UInt16: @Sendable () -> Void] = [:]

    /// Open private-chat rooms keyed by their server-assigned id. The
    /// id is the same value the client sees in the 4-byte chatReference
    /// field of every related transaction.
    private var privateChats: [UInt32: PrivateChat] = [:]

    /// Monotonic id source for private chats. Starts at a value the
    /// real Hotline servers historically used so logs are easy to spot.
    private var nextChatID: UInt32 = 0x1000_0001

    private var nextSocket: UInt16 = 100

    public init(
        advertisedVersion: UInt16,
        agreement: String? = ServerState.defaultAgreement,
        vfs: VFS = FileFixtures.makeRoot(),
        accounts: AccountStore? = nil,
        downloadThrottleKBps: UInt32 = 0
    ) {
        self.advertisedVersion = advertisedVersion
        self.agreement = agreement
        self.plainPosts = [NewsFixtures.initialPlainFeed]
        self.threaded = NewsFixtures.bundleTree
        self.vfs = vfs
        self.accounts = accounts ?? ServerState.makeDefaultAccountStore()
        self.downloadThrottleKBps = downloadThrottleKBps
    }

    private static func makeDefaultAccountStore() -> AccountStore {
        let seedAdmin = ServerAccount(
            login: "admin",
            password: "admin",
            nickname: "Administrator",
            privileges: ServerState.defaultAdminPrivileges
        )
        return AccountStore(seeds: [seedAdmin])
    }

    /// All privilege bits the test server is willing to grant to a
    /// default admin account. Mirrors a "give them everything we know
    /// about" preset.
    public static let defaultAdminPrivileges: UserPrivileges = [
        .deleteFiles, .uploadFiles, .downloadFiles, .renameFiles, .moveFiles,
        .createFolders, .deleteFolders, .renameFolders, .moveFolders,
        .readChat, .sendChat, .initiatePrivateChat, .closePrivateChat,
        .showInList, .createUser, .deleteUser, .readUser, .modifyUser,
        .changeOwnPassword, .readNews, .postNews, .disconnectUsers,
        .cannotBeDisconnected, .getUserInfo, .uploadAnywhere, .useAnyName,
        .dontShowAgreement, .commentFiles, .commentFolders, .viewDropBoxes,
        .makeAliases, .canBroadcast, .deleteArticles, .createCategories,
        .deleteCategories, .createNewsBundles, .deleteNewsBundles,
        .uploadFolders, .downloadFolders, .sendMessages
    ]

    public static let defaultAgreement: String = """
    Welcome to the Heidrun Test Server.

    By connecting you agree to behave nicely while exercising the wire \
    protocol. This banner is fake — it exists only so the client's \
    agreement sheet has something to display.
    """

    // MARK: - Connection lifecycle

    /// Register a new connection, returning its socket id.
    func register(
        nickname: String,
        icon: UInt16,
        privileges: UserPrivileges = [],
        session: Session,
        push: @escaping @Sendable (Data) async -> Void,
        close: @escaping @Sendable () -> Void
    ) -> UInt16 {
        let socket = nextSocket
        nextSocket &+= 1
        users[socket] = User(
            socket: socket,
            icon: icon,
            status: Self.statusForPrivileges(privileges),
            privileges: privileges,
            nickname: nickname
        )
        sessions[socket] = session
        pushSinks[socket] = push
        closeSinks[socket] = close
        return socket
    }

    func unregister(socket: UInt16) {
        users[socket] = nil
        sessions[socket] = nil
        pushSinks[socket] = nil
        closeSinks[socket] = nil
    }

    /// Lookup the per-connection metadata captured at login time. Used
    /// by `handleUserInfo` to render the profile dump; `nil` for a
    /// socket that has logged out (or was never registered).
    func session(forSocket socket: UInt16) -> Session? {
        sessions[socket]
    }

    /// Replace a connected session's `remoteHost` string in place. The
    /// background reverse-DNS task calls this once a PTR record lands
    /// so the next `handleUserInfo` rendering picks up the hostname
    /// instead of the bare IP we stored at login time. No-op for a
    /// socket that has already disconnected.
    func updateSessionRemoteHost(socket: UInt16, host: String) {
        guard var session = sessions[socket] else { return }
        session.remoteHost = host
        sessions[socket] = session
    }

    /// Force the connection owning `socket` to close. The owning
    /// Connection's read loop sees the cancellation, exits, and runs
    /// the normal disconnect teardown. No-op for unknown sockets.
    func closeConnection(socket: UInt16) {
        closeSinks[socket]?()
    }

    func updateUser(socket: UInt16, nickname: String, icon: UInt16) {
        guard var user = users[socket] else { return }
        user.nickname = nickname
        user.icon = icon
        users[socket] = user
    }

    // MARK: - Queries

    var connectedUsers: [User] {
        users.values.sorted { $0.socket < $1.socket }
    }

    var plainFeedJoined: String {
        plainPosts.joined(separator: "\r")
    }

    // MARK: - Mutations

    func appendPlainPost(_ text: String) {
        plainPosts.insert(text, at: 0)
    }

    /// Append a threaded-news post to the category at `path`. Returns
    /// false if the path doesn't terminate at a category.
    func appendThreadedPost(at path: [String], post: Post) -> Bool {
        threaded.appendPost(at: path, post: post)
    }

    /// Broadcast a server-pushed packet to every connected socket.
    func broadcast(_ packet: Data) async {
        let sinks = Array(pushSinks.values)
        for sink in sinks {
            await sink(packet)
        }
    }

    /// Push a packet to a single connected socket, if it's still
    /// registered. Returns `true` when the recipient was found.
    @discardableResult
    func push(to socket: UInt16, packet: Data) async -> Bool {
        guard let sink = pushSinks[socket] else { return false }
        await sink(packet)
        return true
    }

    /// Push a packet to every socket in `sockets` that's still
    /// registered. Sockets that have left are silently skipped.
    func push(to sockets: some Sequence<UInt16>, packet: Data) async {
        for socket in sockets {
            await push(to: socket, packet: packet)
        }
    }

    // MARK: - Private chats

    /// Allocate a new private-chat room with `creator` as the only
    /// initial member and return the chat id. The id slot lives until
    /// the last member leaves.
    func createPrivateChat(creator: UInt16) -> UInt32 {
        let id = nextChatID
        nextChatID &+= 1
        privateChats[id] = PrivateChat(id: id, members: [creator])
        return id
    }

    /// Add `socket` to an existing chat. Returns `false` when the chat
    /// id isn't known.
    @discardableResult
    func joinPrivateChat(_ id: UInt32, socket: UInt16) -> Bool {
        guard var chat = privateChats[id] else { return false }
        chat.members.insert(socket)
        privateChats[id] = chat
        return true
    }

    /// Remove `socket` from `id`. Drops the chat entirely once the last
    /// member leaves so id slots get reclaimed.
    func leavePrivateChat(_ id: UInt32, socket: UInt16) {
        guard var chat = privateChats[id] else { return }
        chat.members.remove(socket)
        if chat.members.isEmpty {
            privateChats[id] = nil
        } else {
            privateChats[id] = chat
        }
    }

    /// Replace the subject. No-op when the chat id isn't known.
    func setPrivateChatSubject(_ id: UInt32, subject: String) {
        guard var chat = privateChats[id] else { return }
        chat.subject = subject
        privateChats[id] = chat
    }

    /// Snapshot of one chat's members. Empty when the chat id isn't
    /// known so callers can treat unknown chats as silently dropped.
    func privateChatMembers(_ id: UInt32) -> Set<UInt16> {
        privateChats[id]?.members ?? []
    }

    /// Drop `socket` from every private chat it belonged to. Returns
    /// the (chatID, remaining members) pairs the caller still needs to
    /// notify with a `privateChatLeft` push so participant lists update
    /// across the surviving members.
    func evictFromAllPrivateChats(socket: UInt16) -> [(id: UInt32, remaining: Set<UInt16>)] {
        var notifications: [(id: UInt32, remaining: Set<UInt16>)] = []
        for (id, chat) in privateChats where chat.members.contains(socket) {
            var updated = chat
            updated.members.remove(socket)
            if updated.members.isEmpty {
                privateChats[id] = nil
            } else {
                privateChats[id] = updated
                notifications.append((id, updated.members))
            }
        }
        return notifications
    }

    // MARK: - Pending transfers

    /// Register a pending transfer and return the new transfer id.
    public func registerTransfer(_ transfer: PendingTransfer) -> UInt32 {
        let id = nextTransferID
        nextTransferID &+= 1
        pendingTransfers[id] = transfer
        return id
    }

    /// Look up (and remove) a pending transfer by id. The side channel
    /// "consumes" the registration once it starts handling it.
    public func takeTransfer(id: UInt32) -> PendingTransfer? {
        pendingTransfers.removeValue(forKey: id)
    }

    /// Park the side-channel `NWConnection` for an in-flight transfer
    /// so a later trans=214 can cancel it. Called by `TransferListener`
    /// right after `takeTransfer` succeeds.
    public func registerActiveTransfer(id: UInt32, connection: NWConnection) {
        activeTransferConnections[id] = connection
    }

    /// Drop the active-transfer registration. Called by `TransferListener`
    /// in its cleanup path, after the transfer completes successfully or
    /// fails.
    public func deregisterActiveTransfer(id: UInt32) {
        activeTransferConnections[id] = nil
    }

    /// Cancel a transfer the client gave up on (trans=214). If the
    /// side channel hasn't connected yet, drop the pending registration
    /// so its eventual HTXF preamble looks unknown and gets rejected. If
    /// the side channel is mid-stream, cancel its `NWConnection` so the
    /// listener's `try await` throws and the handler exits cleanly.
    public func cancelTransfer(id: UInt32) {
        pendingTransfers[id] = nil
        if let connection = activeTransferConnections.removeValue(forKey: id) {
            connection.cancel()
        }
    }

    // MARK: - Admin helpers

    public func adminCreate(_ account: ServerAccount) async throws {
        try await accounts.create(account)
    }

    public func adminModify(
        login: String,
        password: String?,
        nickname: String,
        privileges: UserPrivileges
    ) async throws {
        try await accounts.modify(login: login, password: password, nickname: nickname, privileges: privileges)
    }

    public func adminDelete(login: String) async throws {
        try await accounts.delete(login)
    }

    public func adminOpen(login: String) async -> ServerAccount? {
        await accounts.get(login)
    }

    /// Derive the visible `UserStatus` a user broadcasts to others on
    /// the roster from their privilege bitmask. Real Hotline servers
    /// communicate admin role via the palette byte (high byte of
    /// `hotStatus`), with palette ID 36 — pure red `#ff0000` — being
    /// the canonical "admin" colour the original client renders bold
    /// red. We treat `disconnectUsers` as the canonical admin power
    /// because no regular user has it. The status flag byte stays
    /// zero: classic Hotline only uses those bits for transient state
    /// (away, in-private-chat), never for role.
    static func statusForPrivileges(_ privileges: UserPrivileges) -> UserStatus {
        let adminPaletteID: UInt8 = 36
        let color: UInt8 = privileges.contains(.disconnectUsers) ? adminPaletteID : 0
        return UserStatus(color: color, flags: [])
    }
}
