import Foundation
import NIOCore
import HeidrunCore

/// NIO inbound handler that forwards received bytes into an `AsyncStream<Data>`.
/// Hotline control traffic is small, so copying each chunk out is fine.
final class InboundByteBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            continuation.yield(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish()
        context.close(promise: nil)
    }
}

/// Pulls from the inbound `AsyncStream<Data>` and serves exact-length reads —
/// the one read primitive the packet loop needs. Single-consumer: only the
/// handshake and then the read loop call `receiveExactly`, strictly serially
/// and never concurrently, so the mutable state needs no locking. `@unchecked
/// Sendable` so the owning actor can `await` it without tripping the
/// non-Sendable sending check.
final class ByteAccumulator: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.AsyncIterator
    private var leftover = Data()

    init(stream: AsyncStream<Data>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        while leftover.count < count {
            guard let chunk = await iterator.next() else {
                throw HotlineError.notConnected
            }
            leftover.append(chunk)
        }
        let result = leftover.prefix(count)
        leftover.removeFirst(count)
        return Data(result)
    }
}
