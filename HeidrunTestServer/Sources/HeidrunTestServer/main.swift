import Foundation
import HeidrunCore
import HeidrunTestServerKit

// MARK: - CLI

struct CLIOptions {
    var port: UInt16 = 5500
    var advertisedVersion: UInt16 = 185   // threaded news by default
    var resetAccounts: Bool = false
    var downloadThrottleKBps: UInt32 = 0
}

func parseArgs() -> CLIOptions {
    var options = CLIOptions()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--port":
            if let value = iterator.next(), let port = UInt16(value) { options.port = port }
        case "--version":
            if let value = iterator.next(), let version = UInt16(value) { options.advertisedVersion = version }
        case "--plain":
            options.advertisedVersion = 0    // forces client to use plain UI
        case "--threaded":
            options.advertisedVersion = 185  // forces threaded UI
        case "--reset-accounts":
            options.resetAccounts = true
        case "--throttle":
            if let value = iterator.next(), let rate = UInt32(value) { options.downloadThrottleKBps = rate }
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
      --port <n>          TCP port to listen on (default 5500)
      --version <n>       Server version to advertise (151+ = threaded UI)
      --plain             Force advertised version to 0 (plain-news UI)
      --threaded          Force advertised version to 185 (threaded UI)
      --reset-accounts    Delete the accounts snapshot before starting
                          (admin/admin will be re-seeded)
      --throttle <kbps>   Cap download side-channel at <kbps> KB/s.
                          Useful for resume-flow smoke tests so the
                          operator can `kill -9` Heidrun mid-transfer
                          (e.g. 1024 ≈ 1 MB/s; 300 MB takes ~5 min).
                          Default 0 = unthrottled.
      --help              This message

    Accounts snapshot:
      ~/Library/Application Support/HeidrunTestServer/accounts.json
    """)
}

/// Build the snapshot URL inside Application Support, creating the
/// container directory if needed.
func accountsSnapshotURL() throws -> URL {
    let supportRoot = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let container = supportRoot.appendingPathComponent("HeidrunTestServer", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    return container.appendingPathComponent("accounts.json")
}

// MARK: - Entry point

let options = parseArgs()
do {
    let snapshotURL = try accountsSnapshotURL()

    if options.resetAccounts {
        try? FileManager.default.removeItem(at: snapshotURL)
        print("Removed accounts snapshot at \(snapshotURL.path)")
    }

    // Seed admin/admin on first run only. AccountStore ignores `seeds`
    // when an on-disk snapshot already exists, so subsequent restarts
    // preserve whatever the operator edited through the Admin UI.
    let seedAdmin = ServerAccount(
        login: "admin",
        password: "admin",
        nickname: "Administrator",
        privileges: ServerState.defaultAdminPrivileges
    )
    let accounts = await AccountStore(snapshotURL: snapshotURL, seeds: [seedAdmin])

    let state = ServerState(
        advertisedVersion: options.advertisedVersion,
        accounts: accounts,
        downloadThrottleKBps: options.downloadThrottleKBps
    )
    let server = try TestServerInstance.startFixed(port: options.port, state: state)

    print("HeidrunTestServer listening on 127.0.0.1:\(server.controlPort)")
    print("Transfer side-channel on 127.0.0.1:\(server.transferPort)")
    print("Advertising server version \(options.advertisedVersion) " +
          "(\(options.advertisedVersion >= 151 ? "threaded news" : "plain news") UI)")
    print("Accounts persisted to \(snapshotURL.path)")
    if options.downloadThrottleKBps > 0 {
        print("Download throttle: \(options.downloadThrottleKBps) KB/s")
    }

    // Block forever — Ctrl-C to quit.
    try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
    _ = server
} catch {
    print("Failed to start: \(error)")
    exit(1)
}
