import Foundation

/// Multicasts a stream of `HotlineEvent` values to any number of
/// concurrent subscribers.
///
/// `HotlineClient` exposes `events` as an `AsyncStream<HotlineEvent>`,
/// which is intrinsically single-consumer. To let several feature
/// view-models on the same connection iterate the events independently,
/// each subscriber gets its own stream + continuation; the broadcaster
/// fans new events out to all of them.
public final class EventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<HotlineEvent>.Continuation] = [:]
    private var finished = false

    public init() {}

    /// Hand out a fresh stream. The stream auto-unregisters itself when
    /// its consumer cancels or finishes iterating.
    public func makeStream() -> AsyncStream<HotlineEvent> {
        AsyncStream { continuation in
            let id = UUID()
            let alreadyFinished: Bool = lock.withLock {
                if self.finished { return true }
                self.continuations[id] = continuation
                return false
            }
            if alreadyFinished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Yield an event to every current subscriber.
    public func yield(_ event: HotlineEvent) {
        let snapshot = lock.withLock { Array(continuations.values) }
        for continuation in snapshot {
            continuation.yield(event)
        }
    }

    /// Close every subscriber's stream and refuse new ones.
    public func finish() {
        let snapshot: [AsyncStream<HotlineEvent>.Continuation] = lock.withLock {
            self.finished = true
            let all = Array(self.continuations.values)
            self.continuations.removeAll()
            return all
        }
        for continuation in snapshot {
            continuation.finish()
        }
    }
}
