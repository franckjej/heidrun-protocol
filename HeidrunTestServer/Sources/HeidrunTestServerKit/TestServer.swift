import Foundation
import Network
import HeidrunCore

/// A self-contained test server: control-channel listener on port P,
/// HTXF transfer listener on port P+1, sharing one `ServerState`.
///
/// Used by both the CLI (`HeidrunTestServer` executable) and integration
/// tests in `HeidrunTestServerKitTests`. Tests pick an ephemeral port
/// pair and stop the server in a `defer`.
public final class TestServerInstance: @unchecked Sendable {
    public let state: ServerState
    public let controlPort: UInt16
    public let transferPort: UInt16

    private let controlListener: NWListener
    private let transferListener: NWListener
    private let controlQueue: DispatchQueue
    private let transferQueue: DispatchQueue

    private init(
        state: ServerState,
        controlListener: NWListener,
        transferListener: NWListener,
        controlPort: UInt16
    ) {
        self.state = state
        self.controlListener = controlListener
        self.transferListener = transferListener
        self.controlPort = controlPort
        self.transferPort = controlPort &+ 1
        self.controlQueue = DispatchQueue(label: "HeidrunTestServer.control")
        self.transferQueue = DispatchQueue(label: "HeidrunTestServer.transfer")
    }

    /// Stand up a server bound to a fixed control port. Caller-supplied
    /// state lets tests pre-seed the VFS with fixtures. The transfer
    /// listener takes `port + 1` (Hotline convention).
    public static func startFixed(
        port: UInt16,
        state: ServerState = ServerState(advertisedVersion: 185)
    ) throws -> TestServerInstance {
        let (control, transfer) = try bindPair(port: port)
        let server = TestServerInstance(
            state: state,
            controlListener: control,
            transferListener: transfer,
            controlPort: port
        )
        server.startListeners()
        return server
    }

    /// Stand up a server on a free port pair somewhere in the high-port
    /// range. Returns the running instance.
    public static func startEphemeral(
        state: ServerState = ServerState(advertisedVersion: 185)
    ) throws -> TestServerInstance {
        for _ in 0..<32 {
            // Pick an even base so `base+1` lands on an odd port, keeping
            // both inside the usual ephemeral range.
            let base = UInt16.random(in: 50000...59998) & ~UInt16(1)
            if let pair = try? bindPair(port: base) {
                let server = TestServerInstance(
                    state: state,
                    controlListener: pair.control,
                    transferListener: pair.transfer,
                    controlPort: base
                )
                server.startListeners()
                return server
            }
        }
        throw NSError(domain: "HeidrunTestServer", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "could not find a free control/transfer port pair"
        ])
    }

    public func stop() {
        controlListener.cancel()
        transferListener.cancel()
    }

    private func startListeners() {
        controlListener.newConnectionHandler = { [state, controlQueue] connection in
            let wrapper = Connection(connection: connection, state: state, queue: controlQueue)
            Task { await wrapper.run() }
        }
        transferListener.newConnectionHandler = { [state, transferQueue] connection in
            Task { await TransferListener.handle(connection: connection, state: state, queue: transferQueue) }
        }
        controlListener.start(queue: controlQueue)
        transferListener.start(queue: transferQueue)
    }

    /// Build (but do not start) a listener pair on `port` and `port+1`.
    private static func bindPair(port: UInt16) throws -> (control: NWListener, transfer: NWListener) {
        guard let cp = NWEndpoint.Port(rawValue: port),
              let tp = NWEndpoint.Port(rawValue: port &+ 1) else {
            throw NSError(domain: "HeidrunTestServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid port \(port)"
            ])
        }
        let control = try NWListener(using: .tcp, on: cp)
        let transfer = try NWListener(using: .tcp, on: tp)
        return (control, transfer)
    }
}
