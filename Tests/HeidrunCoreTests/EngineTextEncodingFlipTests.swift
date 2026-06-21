import Foundation
import Testing
@testable import HeidrunCore

/// The engine flips its inbound decode encoding from macOS Roman to UTF-8
/// when (and only when) a correlated reply echoes
/// `CapabilityFlags.textEncoding`. Driven through a scripted fake transport
/// so the flip can be asserted without a live socket.
@Suite("Engine text-encoding flip")
struct EngineTextEncodingFlipTests {

    /// Scripted transport: hands the engine read loop a queue of packets,
    /// captures outbound bytes so the test can read the sent task number.
    actor ScriptedTransport: HotlineTransport {
        private var inbound: [Data]
        private var continuations: [CheckedContinuation<Data, Error>] = []
        private(set) var sent: [Data] = []
        private var pendingBytes = Data()

        init(inbound: [Data]) { self.inbound = inbound }

        func enqueue(_ packet: Data) {
            inbound.append(packet)
            drain()
        }

        func send(_ data: Data) async throws { sent.append(data) }

        func receiveExactly(_ count: Int) async throws -> Data {
            while pendingBytes.count < count {
                guard !inbound.isEmpty else {
                    return try await withCheckedThrowingContinuation { cont in
                        continuations.append(cont)
                        drain()
                    }
                }
                pendingBytes.append(inbound.removeFirst())
            }
            let head = pendingBytes.prefix(count)
            pendingBytes.removeFirst(count)
            return Data(head)
        }

        func close() async {}

        private func drain() {
            while !inbound.isEmpty, !continuations.isEmpty {
                pendingBytes.append(inbound.removeFirst())
            }
        }
    }

    private func loginReply(taskNumber: UInt32, capabilities: UInt16?) -> Data {
        var fields: [PacketField] = []
        if let capabilities { fields.append(.uint16(.capabilities, capabilities)) }
        return PacketCodec.encode(
            classID: 1, transactionID: 0, taskNumber: taskNumber, fields: fields
        )
    }

    @Test("flips to UTF-8 when the login reply echoes textEncoding")
    func flipsOnNegotiation() async throws {
        let transport = ScriptedTransport(inbound: [])
        let engine = HotlineProtocolEngine(
            transport: transport, stringEncoding: .macOSRoman, packetObserver: nil
        )
        await engine.start()

        #expect(await engine.currentStringEncoding == .macOSRoman)

        async let replyTask: Void = {
            // The engine allocates task number 1 for the first send.
            await transport.enqueue(loginReply(
                taskNumber: 1, capabilities: CapabilityFlags.textEncoding.rawValue
            ))
        }()
        _ = try await engine.send(transactionID: 107, fields: [], expectsReply: true)
        await replyTask

        #expect(await engine.currentStringEncoding == .utf8)
        await engine.disconnect()
    }

    @Test("stays macOS Roman when the reply omits textEncoding")
    func staysLegacyWithoutNegotiation() async throws {
        let transport = ScriptedTransport(inbound: [])
        let engine = HotlineProtocolEngine(
            transport: transport, stringEncoding: .macOSRoman, packetObserver: nil
        )
        await engine.start()

        async let replyTask: Void = {
            await transport.enqueue(loginReply(
                taskNumber: 1, capabilities: CapabilityFlags.largeFiles.rawValue
            ))
        }()
        _ = try await engine.send(transactionID: 107, fields: [], expectsReply: true)
        await replyTask

        #expect(await engine.currentStringEncoding == .macOSRoman)
        await engine.disconnect()
    }
}
