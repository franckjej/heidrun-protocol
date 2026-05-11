import Foundation
import HeidrunCore

/// Bridges the `HotlineClient` event stream into `SoundPlayer` calls. One
/// coordinator per connected session; the owning view starts it inside its
/// `.task` and cancels on disappear, mirroring `UserListViewModel`.
@MainActor
public final class SoundCoordinator {
    private let client: any HotlineClient
    private var listenTask: Task<Void, Never>?

    public init(client: any HotlineClient) {
        self.client = client
    }

    public func start() async {
        listenTask?.cancel()
        let stream = client.events
        listenTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                self?.handle(event)
            }
        }
    }

    public func cancel() {
        listenTask?.cancel()
        listenTask = nil
    }

    private func handle(_ event: HotlineEvent) {
        switch event {
        case .chatReceived:
            SoundPlayer.shared.play(.chatPost)
        case .privateChatInvited:
            SoundPlayer.shared.play(.doorbell)
        case .newsPosted:
            SoundPlayer.shared.play(.news)
        case .messageReceived, .broadcastReceived:
            SoundPlayer.shared.play(.serverMessage)
        case .agreementReceived, .disconnected, .privateChatJoined,
             .privateChatLeft, .privateChatSubjectChanged,
             .transferQueueUpdated, .userChanged, .userLeft,
             .userListReceived:
            break
        }
    }
}
