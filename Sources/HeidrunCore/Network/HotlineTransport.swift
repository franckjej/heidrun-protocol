import Foundation

/// Minimal byte-pipe abstraction the protocol engine reads + writes over.
/// Both transports today (Darwin's `NWConnection`, the NIO `Channel`) reduce
/// to this same three-call surface — the rest of the protocol machinery
/// (header framing, dispatch, reply correlation, keepalive, teardown) lives
/// in `HotlineProtocolEngine` and no longer cares which wire is underneath.
///
/// `receiveExactly` is the only read primitive the engine needs: the header
/// is a known-size struct followed by an announced-length body, never
/// streaming. Implementations buffer internally if the underlying transport
/// yields arbitrary chunks (see NIO's `ByteAccumulator`).
public protocol HotlineTransport: Sendable {
    /// Write `data` and resume when the bytes have left the wire (or earlier,
    /// if the transport buffers — only required to be "no longer the
    /// caller's responsibility"). Throws iff the transport is dead.
    func send(_ data: Data) async throws

    /// Pull exactly `count` bytes from the wire. Throws on EOF or transport
    /// failure — the engine's read loop catches the throw and runs teardown.
    func receiveExactly(_ count: Int) async throws -> Data

    /// Close the underlying connection. Idempotent — the engine may call
    /// this during teardown even if the transport already errored.
    func close() async
}
