import Testing
import Foundation
import HeidrunCore
@testable import HeidrunNIOClient

@Suite("ByteAccumulator")
struct ByteAccumulatorTests {
    @Test("reassembles exact byte counts across split chunks")
    func reassembles() async throws {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let accumulator = ByteAccumulator(stream: stream)

        continuation.yield(Data([1, 2, 3]))
        continuation.yield(Data([4, 5]))
        continuation.yield(Data([6, 7, 8, 9]))
        continuation.finish()

        let first = try await accumulator.receiveExactly(4)   // spans chunk 1+2
        let second = try await accumulator.receiveExactly(5)  // spans chunk 2+3
        #expect(Array(first) == [1, 2, 3, 4])
        #expect(Array(second) == [5, 6, 7, 8, 9])
    }

    @Test("throws notConnected when the stream ends short")
    func endsShort() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let accumulator = ByteAccumulator(stream: stream)
        continuation.yield(Data([1, 2]))
        continuation.finish()
        await #expect(throws: HotlineError.self) {
            _ = try await accumulator.receiveExactly(4)
        }
    }
}
