import Foundation
import Network
import Testing
@testable import HeidrunCore

// MARK: - Fake Tracker Server

/// Minimal `NWListener`-based fake that speaks the Hotline tracker protocol,
/// allowing the tracker client tests to run without a live network connection.
private final class MiniTrackerServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private var pendingConnections: [NWConnection] = []
    private var pendingAccepts: [CheckedContinuation<NWConnection, Error>] = []

    private init() throws {
        self.queue = DispatchQueue(label: "MiniTrackerServer")
        self.listener = try NWListener(using: .tcp)
    }

    static func start() async throws -> MiniTrackerServer {
        let server = try MiniTrackerServer()
        server.listener.newConnectionHandler = { [weak server] conn in
            server?.queueIncoming(conn)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let box = ResumeBox<UInt16>(cont)
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = server.listener.port?.rawValue {
                        box.tryResume(.success(p))
                    } else {
                        box.tryResume(.failure(Failure.noPort))
                    }
                case .failed(let err):
                    box.tryResume(.failure(err))
                case .cancelled:
                    box.tryResume(.failure(Failure.cancelled))
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
        let waiting: [CheckedContinuation<NWConnection, Error>] = lock.withLock {
            let w = pendingAccepts; pendingAccepts.removeAll(); return w
        }
        for cont in waiting { cont.resume(throwing: Failure.cancelled) }
    }

    /// Wait for one TCP connection and return it once `.ready`.
    func acceptNextConnection() async throws -> NWConnection {
        let connection: NWConnection = try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                if pendingConnections.isEmpty {
                    pendingAccepts.append(cont)
                } else {
                    cont.resume(returning: pendingConnections.removeFirst())
                }
            }
        }
        try await connection.startAndWaitForReady(on: queue)
        return connection
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

    enum Failure: Error { case noPort, cancelled }
}

private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }
    func tryResume(_ result: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock { defer { cont = nil }; return cont }
        guard let c else { return }
        switch result {
        case .success(let v):
            c.resume(returning: v)
        case .failure(let e):
            c.resume(throwing: e)
        }
    }
}

// MARK: - Wire helpers

/// Build a complete tracker response for the given server list.
private func makeTrackerResponse(
    servers: [TrackerServer],
    encoding: String.Encoding = .macOSRoman
) -> Data {
    // Encode each entry first so we can compute the payload size.
    var entriesData = Data()
    for server in servers {
        let parts = server.address.split(separator: ".").compactMap { UInt8($0) }
        let a = !parts.isEmpty ? parts[0] : 0
        let b = parts.count > 1 ? parts[1] : 0
        let c = parts.count > 2 ? parts[2] : 0
        let d = parts.count > 3 ? parts[3] : 0
        entriesData.append(contentsOf: [a, b, c, d])
        entriesData.appendBigEndian(server.port)
        entriesData.appendBigEndian(server.users)
        entriesData.appendBigEndian(UInt16(0))  // unused

        let nameBytes = server.name.data(using: encoding) ?? Data()
        entriesData.append(UInt8(min(nameBytes.count, 255)))
        entriesData.append(nameBytes.prefix(255))

        let descBytes = server.description.data(using: encoding) ?? Data()
        entriesData.append(UInt8(min(descBytes.count, 255)))
        entriesData.append(descBytes.prefix(255))
    }

    var response = Data()
    // 6-byte echo header
    response.append(contentsOf: [0x48, 0x54, 0x52, 0x4B, 0x00, 0x01])  // "HTRK" + version
    // 8-byte message header
    response.appendBigEndian(UInt16(1))                           // messageType = 1
    response.appendBigEndian(UInt16(entriesData.count + 4))       // dataSize (entries + 2×UInt16 counts)
    response.appendBigEndian(UInt16(servers.count))               // serversInPacket
    response.appendBigEndian(UInt16(servers.count))               // totalServers
    // Entry payload
    response.append(entriesData)
    return response
}

// MARK: - Test Suite

@Suite("HotlineTrackerClient")
struct HotlineTrackerClientTests {

    // MARK: Successful fetches

    @Test("fetches three servers from a fake tracker")
    func fetchThreeServers() async throws {
        let expected: [TrackerServer] = [
            TrackerServer(address: "1.2.3.4", port: 5500, users: 3, name: "Alpha Server", description: "First server"),
            TrackerServer(address: "10.0.0.1", port: 5501, users: 0, name: "Beta Server", description: "Second server"),
            TrackerServer(address: "192.168.1.1", port: 5502, users: 12, name: "Gamma Server", description: "Third server")
        ]

        let fakeServer = try await MiniTrackerServer.start()
        defer { fakeServer.stop() }

        async let serverTask: Void = {
            let conn = try await fakeServer.acceptNextConnection()
            defer { conn.cancel() }
            let handshake = try await conn.receiveExactly(6)
            // Validate client sent correct magic
            assert(Array(handshake.prefix(4)) == [0x48, 0x54, 0x52, 0x4B], "bad magic from client")
            let response = makeTrackerResponse(servers: expected)
            try await conn.sendAsync(response)
        }()

        let result = try await HotlineTrackerClient.fetchServers(
            host: "127.0.0.1",
            port: fakeServer.port
        )
        try await serverTask

        #expect(result.count == 3)
        #expect(result[0].address == "1.2.3.4")
        #expect(result[0].port == 5500)
        #expect(result[0].users == 3)
        #expect(result[0].name == "Alpha Server")
        #expect(result[0].description == "First server")

        #expect(result[1].address == "10.0.0.1")
        #expect(result[1].port == 5501)
        #expect(result[1].users == 0)
        #expect(result[1].name == "Beta Server")

        #expect(result[2].address == "192.168.1.1")
        #expect(result[2].port == 5502)
        #expect(result[2].users == 12)
        #expect(result[2].name == "Gamma Server")
    }

    @Test("returns empty list when tracker reports zero servers")
    func fetchEmptyList() async throws {
        let fakeServer = try await MiniTrackerServer.start()
        defer { fakeServer.stop() }

        async let serverTask: Void = {
            let conn = try await fakeServer.acceptNextConnection()
            defer { conn.cancel() }
            _ = try await conn.receiveExactly(6)   // consume client handshake
            let response = makeTrackerResponse(servers: [])
            try await conn.sendAsync(response)
        }()

        let result = try await HotlineTrackerClient.fetchServers(
            host: "127.0.0.1",
            port: fakeServer.port
        )
        try await serverTask

        #expect(result.isEmpty)
    }

    // MARK: Error handling

    @Test("malformed tracker magic throws malformedReply")
    func badMagicThrows() async throws {
        let fakeServer = try await MiniTrackerServer.start()
        defer { fakeServer.stop() }

        async let serverTask: Void = {
            let conn = try await fakeServer.acceptNextConnection()
            defer { conn.cancel() }
            _ = try await conn.receiveExactly(6)   // consume client handshake
            // Send wrong magic
            try await conn.sendAsync(Data([0x58, 0x58, 0x58, 0x58, 0x00, 0x01]))
        }()

        await #expect(throws: HotlineError.self) {
            _ = try await HotlineTrackerClient.fetchServers(
                host: "127.0.0.1",
                port: fakeServer.port
            )
        }
        try await serverTask
    }

    // MARK: String encoding

    @Test("non-ASCII name and description round-trip via MacRoman")
    func macRomanNameRoundTrip() async throws {
        // These characters are in the Mac OS Roman repertoire but not plain ASCII.
        // "Ñoño Server" with tilde-N (0xD1 in MacRoman), "Información" (0xF3 = ó, 0xF1 = ñ)
        let name = "Ñoño Server"
        let description = "Información general"
        let server = TrackerServer(
            address: "5.6.7.8",
            port: 5500,
            users: 1,
            name: name,
            description: description
        )

        let fakeServer = try await MiniTrackerServer.start()
        defer { fakeServer.stop() }

        async let serverTask: Void = {
            let conn = try await fakeServer.acceptNextConnection()
            defer { conn.cancel() }
            _ = try await conn.receiveExactly(6)
            let response = makeTrackerResponse(servers: [server], encoding: .macOSRoman)
            try await conn.sendAsync(response)
        }()

        let result = try await HotlineTrackerClient.fetchServers(
            host: "127.0.0.1",
            port: fakeServer.port,
            stringEncoding: .macOSRoman
        )
        try await serverTask

        #expect(result.count == 1)
        #expect(result[0].name == name)
        #expect(result[0].description == description)
    }

    @Test("empty name and empty description are handled gracefully")
    func emptyNameAndDescription() async throws {
        let server = TrackerServer(address: "9.9.9.9", port: 5500, users: 0, name: "", description: "")

        let fakeServer = try await MiniTrackerServer.start()
        defer { fakeServer.stop() }

        async let serverTask: Void = {
            let conn = try await fakeServer.acceptNextConnection()
            defer { conn.cancel() }
            _ = try await conn.receiveExactly(6)
            let response = makeTrackerResponse(servers: [server])
            try await conn.sendAsync(response)
        }()

        let result = try await HotlineTrackerClient.fetchServers(
            host: "127.0.0.1",
            port: fakeServer.port
        )
        try await serverTask

        #expect(result.count == 1)
        #expect(result[0].name.isEmpty)
        #expect(result[0].description.isEmpty)
        #expect(result[0].address == "9.9.9.9")
    }

    // MARK: Large list

    @Test("correctly parses 60 servers")
    func largeServerList() async throws {
        let servers: [TrackerServer] = (1...60).map { i in
            TrackerServer(
                address: "10.0.\(i / 256).\(i % 256)",
                port: UInt16(5500 + i),
                users: UInt16(i * 2),
                name: "Server \(i)",
                description: "Description for server \(i)"
            )
        }

        let fakeServer = try await MiniTrackerServer.start()
        defer { fakeServer.stop() }

        async let serverTask: Void = {
            let conn = try await fakeServer.acceptNextConnection()
            defer { conn.cancel() }
            _ = try await conn.receiveExactly(6)
            let response = makeTrackerResponse(servers: servers)
            try await conn.sendAsync(response)
        }()

        let result = try await HotlineTrackerClient.fetchServers(
            host: "127.0.0.1",
            port: fakeServer.port
        )
        try await serverTask

        #expect(result.count == 60)
        for (i, server) in result.enumerated() {
            let n = i + 1
            #expect(server.name == "Server \(n)")
            #expect(server.port == UInt16(5500 + n))
            #expect(server.users == UInt16(n * 2))
        }
    }

    // MARK: TrackerServer model

    @Test("TrackerServer.id is address:port")
    func trackerServerID() {
        let s = TrackerServer(address: "1.2.3.4", port: 5500, users: 0, name: "Test", description: "")
        #expect(s.id == "1.2.3.4:5500")
    }

    @Test("TrackerServer is Hashable and Equatable")
    func trackerServerHashable() {
        let a = TrackerServer(address: "1.2.3.4", port: 5500, users: 3, name: "X", description: "Y")
        let b = TrackerServer(address: "1.2.3.4", port: 5500, users: 3, name: "X", description: "Y")
        let c = TrackerServer(address: "1.2.3.4", port: 5501, users: 3, name: "X", description: "Y")
        #expect(a == b)
        #expect(a != c)
        var set = Set<TrackerServer>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}
