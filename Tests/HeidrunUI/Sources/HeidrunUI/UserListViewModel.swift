import Foundation
import Observation
import HeidrunCore

/// Live user-roster view model owned by the host window. Subscribes to the
/// client's event stream, applies user-list deltas, and exposes a couple of
/// row-action wrappers (`sendIM`, `requestInfo`).
@Observable
@MainActor
public final class UserListViewModel {
    public private(set) var users: [User] = []
    public private(set) var loadError: String?

    private let client: any HotlineClient
    private var eventTask: Task<Void, Never>?

    public init(client: any HotlineClient) {
        self.client = client
    }

    public func start() async {
        do {
            users = try await client.fetchUserList()
            loadError = nil
            Self.logUsers("fetched", users: users)
        } catch {
            loadError = String(describing: error)
        }
        if eventTask == nil {
            let stream = client.events
            eventTask = Task { [weak self] in
                for await event in stream {
                    await self?.apply(event: event)
                }
            }
        }
    }

    public func cancel() {
        eventTask?.cancel()
        eventTask = nil
    }

    public func sendIM(to socket: UInt16, body: String) async throws {
        try await client.sendPrivateMessage(body, to: socket)
    }

    public func requestInfo(for socket: UInt16) async throws -> UserInfo {
        try await client.fetchUserInfo(socket: socket)
    }

    private func apply(event: HotlineEvent) {
        switch event {
        case .userListReceived(let list):
            users = list
            loadError = nil
            Self.logUsers("received", users: list)
        case .userChanged(let user):
            if let idx = users.firstIndex(where: { $0.socket == user.socket }) {
                users[idx] = user
            } else {
                users.append(user)
            }
            Self.log("changed socket=\(user.socket) icon=\(user.icon) nick=\(user.nickname)")
        case .userLeft(let socket):
            users.removeAll { $0.socket == socket }
        default:
            break
        }
    }

    private nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[UserList] \(message)\n".utf8))
    }

    private nonisolated static func logUsers(_ source: String, users: [User]) {
        let summary = users.prefix(20).map { "\($0.socket):icon=\($0.icon):\($0.nickname)" }.joined(separator: ", ")
        let suffix = users.count > 20 ? " (+\(users.count - 20) more)" : ""
        log("\(source) \(users.count) user(s) — \(summary)\(suffix)")
    }
}
