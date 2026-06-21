#if canImport(Network)
import Foundation
import Network
@testable import HeidrunCore

/// Lightweight `NWListener`-based fake server for the NIO client integration
/// tests — a copy of HeidrunCore's `MiniHotlineServer`, renamed. Darwin-only
/// (NWListener); these tests run on macOS, and the client's dispatch logic is
/// identical on Linux.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private var pendingConnections: [NWConnection] = []
    private var pendingAccepts: [CheckedContinuation<NWConnection, Error>] = []

    private init() throws {
        self.queue = DispatchQueue(label: "LoopbackServer")
        self.listener = try NWListener(using: .tcp)
    }

    static func start() async throws -> LoopbackServer {
        let server = try LoopbackServer()
        server.listener.newConnectionHandler = { [weak server] conn in
            server?.queueIncoming(conn)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let box = ServerResumeBox<UInt16>(cont)
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = server.listener.port?.rawValue {
                        box.tryResume(.success(p))
                    } else {
                        box.tryResume(.failure(LoopbackServer.Failure.noPort))
                    }
                case .failed(let err):
                    box.tryResume(.failure(err))
                case .cancelled:
                    box.tryResume(.failure(LoopbackServer.Failure.cancelled))
                default:
                    break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.port = port
        return server
    }

    func stop() {
        listener.cancel()
        let drained = lock.withLock { () -> [CheckedContinuation<NWConnection, Error>] in
            let waiting = pendingAccepts
            pendingAccepts.removeAll()
            return waiting
        }
        for cont in drained { cont.resume(throwing: Failure.cancelled) }
    }

    func acceptNextConnection() async throws -> NWConnection {
        let connection: NWConnection = try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if pendingConnections.isEmpty {
                    pendingAccepts.append(cont)
                } else {
                    let conn = pendingConnections.removeFirst()
                    cont.resume(returning: conn)
                }
            }
        }
        try await connection.startAndWaitForReady(on: queue)
        return connection
    }

    func acceptHandshake() async throws -> ServerConnection {
        let connection = try await acceptNextConnection()
        let sc = ServerConnection(connection: connection, encoding: .macOSRoman)
        try await sc.performHandshake()
        return sc
    }

    private func queueIncoming(_ connection: NWConnection) {
        let cont: CheckedContinuation<NWConnection, Error>? = lock.withLock {
            if pendingAccepts.isEmpty {
                pendingConnections.append(connection)
                return nil
            } else {
                return pendingAccepts.removeFirst()
            }
        }
        cont?.resume(returning: connection)
    }

    enum Failure: Error {
        case noPort
        case cancelled
    }
}

final class ServerConnection: @unchecked Sendable {
    let connection: NWConnection
    let encoding: String.Encoding

    init(connection: NWConnection, encoding: String.Encoding) {
        self.connection = connection
        self.encoding = encoding
    }

    func performHandshake() async throws {
        let magic = try await connection.receiveExactly(12)
        guard magic.prefix(8) == Data([
            0x54, 0x52, 0x54, 0x50, 0x48, 0x4F, 0x54, 0x4C
        ]) else {
            throw HotlineError.malformedReply(reason: "bad client magic")
        }
        try await connection.sendAsync(Data([
            0x54, 0x52, 0x54, 0x50, 0x00, 0x00, 0x00, 0x00
        ]))
    }

    func readPacket() async throws -> ReceivedPacket {
        let headerBytes = try await connection.receiveExactly(PacketHeader.byteCount)
        guard let header = PacketHeader(decoding: headerBytes) else {
            throw HotlineError.malformedReply(reason: "short header")
        }
        let body: Data
        if header.dataLength > 0 {
            body = try await connection.receiveExactly(Int(header.dataLength))
        } else {
            body = Data()
        }
        return ReceivedPacket(header: header, fields: PacketCodec.decodeBody(body))
    }

    func sendReply(
        transactionID: UInt16,
        taskNumber: UInt32,
        errorID: UInt32 = 0,
        fields: [PacketField] = []
    ) async throws {
        let packet = PacketCodec.encode(
            classID: 1, transactionID: transactionID, taskNumber: taskNumber,
            errorID: errorID, fields: fields
        )
        try await connection.sendAsync(packet)
    }

    func sendPush(
        transactionID: UInt16,
        taskNumber: UInt32 = 0,
        fields: [PacketField] = []
    ) async throws {
        let packet = PacketCodec.encode(
            classID: 0, transactionID: transactionID, taskNumber: taskNumber, errorID: 0, fields: fields
        )
        try await connection.sendAsync(packet)
    }

    func close() { connection.cancel() }
}

struct ReceivedPacket: Sendable {
    let header: PacketHeader
    let fields: [PacketField]
}

private final class ServerResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func tryResume(_ result: Result<T, Error>) {
        let captured: CheckedContinuation<T, Error>? = lock.withLock {
            defer { cont = nil }
            return cont
        }
        guard let c = captured else { return }
        switch result {
        case .success(let v): c.resume(returning: v)
        case .failure(let e): c.resume(throwing: e)
        }
    }
}
#endif
