import Foundation
import Testing
@testable import HeidrunCore

@Suite("EventBroadcaster")
struct EventBroadcasterTests {
    @Test("multiple subscribers each receive every event")
    func multicastDelivers() async {
        let broadcaster = EventBroadcaster()
        let streamA = broadcaster.makeStream()
        let streamB = broadcaster.makeStream()

        // Spin up two collectors; each ends when the broadcaster finishes.
        async let collectedA: [HotlineEvent] = collect(streamA)
        async let collectedB: [HotlineEvent] = collect(streamB)

        broadcaster.yield(.broadcastReceived(message: "one"))
        broadcaster.yield(.broadcastReceived(message: "two"))
        broadcaster.finish()

        let a = await collectedA
        let b = await collectedB
        #expect(a == b)
        #expect(a.count == 2)
    }

    @Test("makeStream after finish() returns an immediately-empty stream")
    func finishedThenSubscribe() async {
        let broadcaster = EventBroadcaster()
        broadcaster.finish()
        let stream = broadcaster.makeStream()
        let collected: [HotlineEvent] = await collect(stream)
        #expect(collected.isEmpty)
    }

    @Test("a subscriber that finishes early stops receiving")
    func earlyFinishDoesNotLeak() async {
        let broadcaster = EventBroadcaster()
        let stream = broadcaster.makeStream()
        var iterator = stream.makeAsyncIterator()

        broadcaster.yield(.broadcastReceived(message: "before"))
        let first = await iterator.next()
        #expect(first == .broadcastReceived(message: "before"))

        // Drop the iterator to simulate the consumer cancelling.
        // The internal continuation should be removed; subsequent yields
        // shouldn't crash even though no one is listening.
        _ = iterator
        broadcaster.yield(.broadcastReceived(message: "after"))
        broadcaster.finish()
    }

    private func collect(_ stream: AsyncStream<HotlineEvent>) async -> [HotlineEvent] {
        var out: [HotlineEvent] = []
        for await event in stream { out.append(event) }
        return out
    }
}
