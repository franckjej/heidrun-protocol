import Foundation
import HeidrunCore

/// Shared, mutable state across all connected clients.
///
/// Heidrun's test server is a single-process toy — one actor holds every
/// piece of mutable state and serialises access. Concurrent clients
/// drive the actor with await, no locks of our own.
actor ServerState {
    /// Server version we advertise in the login reply. The client maps
    /// `< 151` → plain-only news UI, `>= 151` → threaded news UI.
    let advertisedVersion: UInt16

    /// Newest-first list of plain-news posts. `getNewsList` joins these
    /// with "\r" separators (Hotline convention).
    private(set) var plainPosts: [String] = []

    /// Threaded-news fixture tree (folders/categories/posts).
    private(set) var threaded: [BundleNode]

    /// Connected users, keyed by socket.
    private var users: [UInt16: User] = [:]

    /// Per-connection event sinks. When a client posts plain news, every
    /// connected user should see a `kInfoNewPost` push.
    private var pushSinks: [UInt16: @Sendable (Data) async -> Void] = [:]

    private var nextSocket: UInt16 = 100

    init(advertisedVersion: UInt16) {
        self.advertisedVersion = advertisedVersion
        self.plainPosts = [NewsFixtures.initialPlainFeed]
        self.threaded = NewsFixtures.bundleTree
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

    /// Broadcast a server-pushed packet to every connected socket.
    func broadcast(_ packet: Data) async {
        let sinks = Array(pushSinks.values)
        for sink in sinks {
            await sink(packet)
        }
    }
}
