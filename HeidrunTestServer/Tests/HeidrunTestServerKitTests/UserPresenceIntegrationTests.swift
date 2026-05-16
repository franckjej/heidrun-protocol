import Foundation
import Testing
import HeidrunCore
import HeidrunTestServerKit

/// End-to-end checks that the test server announces user presence
/// transitions (`userChanged` 301, `userLeft` 302) to the rest of the
/// connected clients.
@Suite("HotlineNetworkClient ↔ TestServerInstance — user presence")
struct UserPresenceIntegrationTests {

    @Test("login reply propagates the server-assigned socket")
    func loginRepliesWithOwnSocket() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }

        let client = try await loggedInClient(controlPort: server.controlPort, nickname: "Tester")
        defer { Task { await client.disconnect() } }

        let socket = await client.connectionInfo.connectionSocket
        // The test server starts handing out sockets at 100; the first
        // login should land at 100 exactly.
        #expect(socket == 100)
    }

    @Test("a peer disconnect surfaces as .userLeft to the remaining clients")
    func peerLeaveAnnouncesUserLeft() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }

        // Watcher logs in first so a single-shot Task can start
        // collecting events before the leaver shows up.
        let watcher = try await loggedInClient(controlPort: server.controlPort, nickname: "Watcher")
        defer { Task { await watcher.disconnect() } }

        // Drain events on a side task. AsyncStream registers its
        // continuation lazily on the first iteration, so we have to
        // ensure the for-await has actually started before any events
        // we care about are yielded — otherwise the broadcaster fans
        // out into nothing.
        let events = EventCollector()
        let subscribed = AsyncStream<Void>.makeStream()
        let drain = Task {
            var first = true
            for await event in watcher.events {
                if first {
                    subscribed.continuation.finish()
                    first = false
                }
                await events.append(event)
            }
            if first { subscribed.continuation.finish() }
        }
        defer { drain.cancel() }
        // Kick the broadcaster so the subscription closure actually
        // runs. A `userChanged` for the watcher itself works because
        // the test server pushes 301 on every nickname update.
        try await watcher.changeNickname("Watcher", icon: 1, persist: false)
        for await _ in subscribed.stream { break }

        // Leaver logs in, then disconnects. The TCP FIN should reach
        // the server's read loop, which fires `announceUserLeft`. We
        // pick up the leaver's socket from the watcher's roster — the
        // client's own `connectionInfo.connectionSocket` is wired up
        // separately and not exercised here.
        let leaver = try await loggedInClient(controlPort: server.controlPort, nickname: "Leaver")
        try await waitFor {
            await events.contains { event in
                if case .userChanged(let user) = event, user.nickname == "Leaver" {
                    return true
                }
                return false
            }
        }
        let leaverSocket = await events.firstSocket(forNickname: "Leaver") ?? 0
        await leaver.disconnect()

        try await waitFor {
            await events.contains { event in
                if case .userLeft(let socket) = event, socket == leaverSocket {
                    return true
                }
                return false
            }
        }
    }

    @Test("kick disconnects the target and announces userLeft to the rest")
    func kickDisconnectsTargetAndAnnouncesLeave() async throws {
        let server = try TestServerInstance.startEphemeral()
        defer { server.stop() }

        let kicker = try await loggedInClient(controlPort: server.controlPort, nickname: "Kicker")
        defer { Task { await kicker.disconnect() } }

        // Subscribe to the kicker's events so we can verify the userLeft
        // push lands once the target's connection is dropped.
        let kickerEvents = EventCollector()
        let subscribed = AsyncStream<Void>.makeStream()
        let drain = Task {
            var first = true
            for await event in kicker.events {
                if first {
                    subscribed.continuation.finish()
                    first = false
                }
                await kickerEvents.append(event)
            }
            if first { subscribed.continuation.finish() }
        }
        defer { drain.cancel() }
        try await kicker.changeNickname("Kicker", icon: 1, persist: false)
        for await _ in subscribed.stream { break }

        // Target logs in and we wait until the kicker sees its userChanged
        // so we have the target's server-assigned socket id.
        let target = try await loggedInClient(controlPort: server.controlPort, nickname: "Target")
        try await waitFor {
            await kickerEvents.contains { event in
                if case .userChanged(let user) = event, user.nickname == "Target" {
                    return true
                }
                return false
            }
        }
        let targetSocket = await kickerEvents.firstSocket(forNickname: "Target") ?? 0
        #expect(targetSocket != 0)

        // Subscribe to the target's events BEFORE the kick lands so we
        // can observe the .disconnected push surfaced when the test
        // server cancels its NWConnection.
        let targetEvents = EventCollector()
        let targetDrain = Task {
            for await event in target.events {
                await targetEvents.append(event)
            }
        }
        defer { targetDrain.cancel() }

        try await kicker.kick(socket: targetSocket, ban: false)

        // The target sees a transport-level .disconnected event.
        try await waitFor {
            await targetEvents.contains { event in
                if case .disconnected = event { return true }
                return false
            }
        }
        // The kicker sees the userLeft broadcast for the target's socket.
        try await waitFor {
            await kickerEvents.contains { event in
                if case .userLeft(let socket) = event, socket == targetSocket {
                    return true
                }
                return false
            }
        }
    }

    // MARK: - Helpers

    private func loggedInClient(controlPort: UInt16, nickname: String) async throws -> HotlineNetworkClient {
        let client = try await HotlineNetworkClient.connect(
            settings: ConnectionSettings(
                name: "test",
                address: "127.0.0.1",
                port: controlPort
            )
        )
        try await client.login(name: "guest", password: "", nickname: nickname, icon: 1)
        return client
    }

    private func waitFor(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("waitFor timed out")
    }
}

private actor EventCollector {
    private var events: [HotlineEvent] = []

    func append(_ event: HotlineEvent) {
        events.append(event)
    }

    func contains(where predicate: (HotlineEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }

    func firstSocket(forNickname nickname: String) -> UInt16? {
        for event in events {
            if case .userChanged(let user) = event, user.nickname == nickname {
                return user.socket
            }
        }
        return nil
    }
}
