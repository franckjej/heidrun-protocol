import Foundation
import Network

// MARK: - CLI

struct CLIOptions {
    var port: UInt16 = 5500
    var advertisedVersion: UInt16 = 185   // threaded news by default
}

func parseArgs() -> CLIOptions {
    var options = CLIOptions()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--port":
            if let v = iterator.next(), let port = UInt16(v) { options.port = port }
        case "--version":
            if let v = iterator.next(), let version = UInt16(v) { options.advertisedVersion = version }
        case "--plain":
            options.advertisedVersion = 0    // forces client to use plain UI
        case "--threaded":
            options.advertisedVersion = 185  // forces threaded UI
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            print("Unknown argument: \(arg)")
            printUsage()
            exit(1)
        }
    }
    return options
}

func printUsage() {
    print("""
    HeidrunTestServer — a local Hotline server for poking at Heidrun.

    Usage:
      swift run --package-path Packages/HeidrunTestServer HeidrunTestServer [options]

    Options:
      --port <n>       TCP port to listen on (default 5500)
      --version <n>    Server version to advertise (151+ = threaded UI)
      --plain          Force advertised version to 0 (plain-news UI)
      --threaded       Force advertised version to 185 (threaded UI)
      --help           This message
    """)
}

// MARK: - Listener

@MainActor
final class Listener {
    let listener: NWListener
    let state: ServerState
    let queue: DispatchQueue

    init(port: UInt16, state: ServerState) throws {
        self.state = state
        self.queue = DispatchQueue(label: "HeidrunTestServer")
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "TestServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid port \(port)"
            ])
        }
        self.listener = try NWListener(using: .tcp, on: nwPort)
    }

    func run() async throws {
        listener.newConnectionHandler = { [state, queue] connection in
            let wrapper = Connection(connection: connection, state: state, queue: queue)
            Task { await wrapper.run() }
        }
        listener.start(queue: queue)

        // Block forever — Ctrl-C to quit.
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
    }
}

// MARK: - Entry point

let options = parseArgs()
let state = ServerState(advertisedVersion: options.advertisedVersion)
do {
    let listener = try await Listener(port: options.port, state: state)
    print("HeidrunTestServer listening on 127.0.0.1:\(options.port)")
    print("Advertising server version \(options.advertisedVersion) " +
          "(\(options.advertisedVersion >= 151 ? "threaded news" : "plain news") UI)")
    try await listener.run()
} catch {
    print("Failed to start: \(error)")
    exit(1)
}
