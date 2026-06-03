<pre align="center">
   __         _     __               
  / /_  ___  (_)___/ /______  ______ 
 / __ \/ _ \/ / __  / ___/ / / / __ \
/ / / /  __/ / /_/ / /  / /_/ / / / /
\/ /_/\___/_/\__,_/_/   \__,_/_/ /_/ 
</pre>

# heidrun-protocol

[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-blue.svg)]()
[![License: GPL v2](https://img.shields.io/badge/License-GPLv2-blue.svg)](https://www.gnu.org/licenses/gpl-2.0.html)

Hotline-protocol wire format, codecs, and clients for the [Heidrun][heidrun] Mac client and HeidrunServer. Pure Swift 6; the value layer has no Apple-only dependencies, so it builds on both macOS and Linux.

## Modules

- **`HeidrunCore`** — wire-level value types (`PacketHeader`, `PacketObject`, `TransactionType`, `RemotePath`, `ConnectionSettings`), codecs (`PacketCodec`, `FileListEntryCodec`, `NewsBundleEntryCodec`, …), the Network.framework-based `HotlineNetworkClient`, and `HotlineTrackerClient`. Apple-only files are `#if canImport(Network)`-gated so Linux builds skip them cleanly.
- **`HeidrunNIOClient`** — cross-platform Hotline transport on SwiftNIO. Reuses `HeidrunCore`'s codecs and `EventBroadcaster`.
- **`heidrun`** — text-only Hotline CLI ("modern HX") built on `HeidrunNIOClient`.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/franckjej/heidrun-protocol.git", exact: "1.0.0-rc15")
]

// in a target's dependencies:
.product(name: "HeidrunCore", package: "heidrun-protocol")
```

Pin pre-release tags with `exact:`, never `from:` — SemVer pre-release identifiers compare lexically, so `from: "1.0.0-rc10"` quietly resolves back to `rc9` (`'1' < '9'`).

## Building

```bash
swift build
swift test
```

## The `heidrun` CLI

```bash
swift run heidrun <host[:port]> -l <login> -p <pw> -n <nick>
```

Opens an interactive Hotline session. The REPL works like classic HX:

- **Chat** — bare text → public; `/msg <socket> <text>`, `/me <action>`
- **Users** — `/who`, `/info <socket>`, `/nick <name>`
- **Files** — `/ls [path]`, `/finfo <path>`, `/get <path>`, `/put <local> [<remote-dir>]` (HTXF, 64 KiB chunks, progress)
- **News (plain)** — `/news`, `/post <text>`
- **News (threaded)** — `/tnews [path]`, `/tthreads <path>`, `/tread <path> <id>`, `/tpost <path> | <title> | <body>`, `/treply <path> <id> | <body>`
- **Server-forwarded** — any unrecognised `/cmd` is forwarded as chat (e.g. `/topic <subject>`). `//foo` sends the literal text `/foo`.
- **Housekeeping** — `/quit`, `/help`

Arrow keys browse command history (persists at `~/.heidrun_history`); TAB completes builtin command names; the connection auto-reconnects on disconnect with capped exponential backoff.

## Protocol extensions

Heidrun layers additive, non-standard extensions on top of base Hotline (e.g. emoji user avatars). They degrade gracefully to standard behaviour on vanilla servers. Wire layouts are specified in [`docs/PROTOCOL-EXTENSIONS.md`](docs/PROTOCOL-EXTENSIONS.md).

## Wire-protocol notes

- All multi-byte ints are **big-endian**.
- String encoding defaults to `.macOSRoman`; overridable per connection.
- Login + password obfuscation: XOR every byte with `0xFF` on classic login (TX 107) and most account-admin transactions — **except** `openLogin` (352), where login goes plain.
- Path encoding (objIDs 202, 212, 325): `UInt16 componentCount` + per-component `(UInt16 0, UInt8 length, name bytes)`.
- HTXF handshake variants:
  - **File download** — `"HTXF"` + `UInt32 transferID` + `UInt32 transferSize` + `UInt32 reserved (0)`.
  - **Folder upload** — the trailing 4 bytes become `UInt16 1, 0`.
  - **Folder download** — 18 bytes with a `UInt16 3` sentinel.
- Hotline timestamps: seconds since `1904-01-01 00:00:00 UTC` (classic Mac epoch). See `HotlineDate`.
- File upload framing: `FILP` 40-byte header (forkCount=3) → `INFO` block (74 + nameLen) with HFS type/creator + 1904-epoch dates + name → `DATA` fork header (16 B) + data fork → `MACR` fork header (16 B) + resource fork. Resource forks round-trip on single-file uploads, folder uploads, and folder downloads; pass an empty `Data` for data-fork-only files.

## License

GPL-2.0. Full text in [`LICENSE`](LICENSE).

The macOS client this package serves is a Swift port of the 2002 Heidrun Hotline client by Göran Granström, whose original plug-in modules were GPL-2.0; this package shares that lineage.

### Dual licensing

Copyright © Daubit & Francke GmbH. The copyright holder reserves all rights to license this code under other terms — commercial, proprietary, BSD/MIT-style, or any other arrangement — for its own products and for third parties on request. The GPL-2.0 grant above governs public/community use; it does not bind the copyright holder's re-use of the same code under different terms.

For a non-GPL licence: `jens.francke@daubit-francke.de`.

### Third-party

Links the following Apache 2.0 packages: [swift-nio](https://github.com/apple/swift-nio) and [swift-argument-parser](https://github.com/apple/swift-argument-parser), plus transitively swift-atomics, swift-collections, and swift-system.

[heidrun]: https://github.com/franckjej/heidrun
