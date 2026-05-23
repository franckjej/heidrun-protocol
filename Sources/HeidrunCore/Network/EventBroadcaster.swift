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
    ///
    /// Uses `AsyncStream.makeStream` so the continuation is registered
    /// EAGERLY — events yielded between this call and the consumer's
    /// first `for await` iteration are buffered into the stream's
    /// internal queue (unbounded). The legacy `AsyncStream(_:_:)`
    /// closure init was lazy: it registered the continuation only when
    /// iteration began, so any event broadcast during the window
    /// between subscription and iteration was silently lost — the
    /// root cause of the ghost-client desync where a new joiner's
    /// `userChanged` push missed a peer that had subscribed but not
    /// yet started consuming.
    public func makeStream() -> AsyncStream<HotlineEvent> {
        let (stream, continuation) = AsyncStream<HotlineEvent>.makeStream()
        let id = UUID()
        let alreadyFinished: Bool = lock.withLock {
            if self.finished { return true }
            self.continuations[id] = continuation
            return false
        }
        if alreadyFinished {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
        }
        return stream
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
