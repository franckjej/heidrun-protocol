import Foundation
import Network

/// Async wrappers around `NWConnection`'s callback-based primitives.
///
/// `NWConnection.send` and `.receive` use completion handlers; these
/// extensions bridge them to Swift's `async`/`await` so the client actor
/// can write straight-line wire code.
extension NWConnection {
    /// Send `data` and resume when the lower stack reports the bytes have
    /// been processed (queued for transmission, not necessarily delivered).
    public func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Read exactly `count` bytes. Throws when the connection ends before
    /// the buffer fills. Avoids the `NWConnection.receive(min:max:)` quirk
    /// where `min == max` can still deliver fewer bytes if the stream
    /// closes mid-read.
    public func receiveExactly(_ count: Int) async throws -> Data {
        var collected = Data()
        collected.reserveCapacity(count)
        while collected.count < count {
            let remaining = count - collected.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                self.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: HotlineError.notConnected)
                    } else {
                        cont.resume(throwing: HotlineError.notConnected)
                    }
                }
            }
            collected.append(chunk)
        }
        return collected
    }

    /// Start the connection and resume once it's `.ready` (or throw on
    /// `.failed` / `.cancelled`).
    public func startAndWaitForReady(on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Local actor protecting "fired exactly once" semantics so we
            // never call `cont.resume` twice if the state goes
            // .preparing → .ready and then .failed.
            let box = ContinuationBox(cont: cont)
            self.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.tryResume(.success(()))
                case .failed(let err):
                    box.tryResume(.failure(err))
                case .cancelled:
                    box.tryResume(.failure(HotlineError.notConnected))
                default:
                    break
                }
            }
            self.start(queue: queue)
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?

    init(cont: CheckedContinuation<Void, Error>) {
        self.cont = cont
    }

    func tryResume(_ result: Result<Void, Error>) {
        let captured: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { self.cont = nil }
            return self.cont
        }
        guard let c = captured else { return }
        switch result {
        case .success:
            c.resume()
        case .failure(let e):
            c.resume(throwing: e)
        }
    }
}
