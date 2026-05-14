import Foundation
import HeidrunCore

/// Shared, mutable state across all connected clients.
///
/// Heidrun's test server is a single-process toy — one actor holds every
/// piece of mutable state and serialises access. Concurrent clients
/// drive the actor with await, no locks of our own.
public actor ServerState {
    /// Server version we advertise in the login reply. The client maps
    /// `< 151` → plain-only news UI, `>= 151` → threaded news UI.
    public let advertisedVersion: UInt16

    /// Newest-first list of plain-news posts. `getNewsList` joins these
    /// with "\r" separators (Hotline convention).
    public private(set) var plainPosts: [String] = []

    /// Threaded-news fixture tree (folders/categories/posts).
    private(set) var threaded: [BundleNode]

    /// In-memory file system the file-transfer transactions read from
    /// and write to. The HTXF side channel keys into `pendingTransfers`
    /// to know what each connecting transfer port is for.
    public let vfs: VFS

    /// Side-channel transfers the control channel has authorised but
    /// the HTXF listener hasn't seen yet.
    private var pendingTransfers: [UInt32: PendingTransfer] = [:]

    /// Monotonic transfer id counter. Shared across downloads/uploads.
    private var nextTransferID: UInt32 = 1

    /// Connected users, keyed by socket.
    private var users: [UInt16: User] = [:]

    /// Per-connection event sinks. When a client posts plain news, every
    /// connected user should see a `kInfoNewPost` push.
    private var pushSinks: [UInt16: @Sendable (Data) async -> Void] = [:]

    private var nextSocket: UInt16 = 100

    public init(advertisedVersion: UInt16, vfs: VFS = FileFixtures.makeRoot()) {
        self.advertisedVersion = advertisedVersion
        self.plainPosts = [NewsFixtures.initialPlainFeed]
        self.threaded = NewsFixtures.bundleTree
        self.vfs = vfs
    }

    // MARK: - Connection lifecycle

    /// Register a new connection, returning its socket id.
    func register(
        nickname: String,
        icon: UInt16,
        push: @escaping @Sendable (Data) async -> Void
    ) -> UInt16 {
        let socket = nextSocket
        nextSocket &+= 1
        users[socket] = User(
            socket: socket,
            icon: icon,
            status: UserStatus(rawValue: 0),
            privileges: [],
            nickname: nickname
        )
        pushSinks[socket] = push
        return socket
    }

    func unregister(socket: UInt16) {
        users[socket] = nil
        pushSinks[socket] = nil
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
}
