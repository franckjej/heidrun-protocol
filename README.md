# heidrun-protocol

Shared protocol + wire-format library for the [Heidrun][heidrun-swift]
Hotline-protocol client and [HeidrunServer][heidrun-server]. Pure Swift,
no Apple-only dependencies on the value layer, builds on macOS and
Linux.

## What's in here

- `Sources/HeidrunCore/` — the package itself.
  - `Protocol/` — wire-level value types (`PacketHeader`,
    `PacketObject`, `TransactionType`, `RemotePath`,
    `ConnectionSettings`, `ByteIO` helpers, `HotlineError`).
  - `Models/` — domain types (`User`, `RemoteFile`, `News`, `Icon`,
    `FourCharCode`, …).
  - `Network/` — codecs (`PacketCodec`, `FileListEntryCodec`,
    `NewsBundleEntryCodec`, `FolderUploadFraming`, `UploadFraming`,
    `TrackerRegistrationCodec`, …) plus the `NWConnection`-based
    `HotlineNetworkClient` and `HotlineTrackerClient`. The Apple-
    only files are gated by `#if canImport(Network)` so HeidrunServer
    can build them on Linux without the symbols being live.
- `Sources/HeidrunNIOClient/` — `NIOHotlineClient`, the
  cross-platform (Linux + macOS) SwiftNIO transport. Reuses
  HeidrunCore's codecs + `EventBroadcaster`; only the wire transport
  is new.
- `Sources/heidrun/` — `heidrun` executable, a text-only Hotline
  CLI ("modern HX") built on `NIOHotlineClient`. See _Heidrun CLI_
  below.
- `Tests/HeidrunCoreTests/` — codec + loopback integration tests.
- `Tests/HeidrunNIOClientTests/` — NIO transport + per-transaction
  round-trip tests via the existing `LoopbackServer`.
- `HeidrunTestServer/` — sibling Swift package, a small loopback
  `NWListener`-backed fake server used while cross-referencing wire
  formats during the original Obj-C → Swift port. Not exposed via
  the root Package.swift; `cd HeidrunTestServer && swift run` to use
  it.

## Heidrun CLI

`swift run heidrun <host[:port]> -l <login> -p <pw> -n <nick>` opens an
interactive Hotline session. The REPL works like classic HX:

- bare text → public chat
- `/who`, `/info <socket>`, `/msg <socket> <text>`, `/me <action>`,
  `/nick <name>` — client-side commands
- `/ls [path]`, `/finfo <path/file>` — file system browse
- `/get <path/file>`, `/put <local> [<remote-dir>]` — HTXF file
  transfers (separate-channel TCP, streamed in 64 KiB chunks so
  multi-GB transfers don't sit in memory; progress prints `↑/↓ N%`)
- `/news` and `/post <text>` — plain (bulletin-board) news
- `/tnews [path]`, `/tthreads <path>`, `/tread <path> <id>` — threaded
  news read
- `/tpost <path> | <title> | <body>`,
  `/treply <path> <id> | <body>` — threaded news post + reply
  (reply auto-derives `Re: <parent title>`, one `Re:` deep)
- `/quit`, `/help` — housekeeping
- `/topic <subject>` (and any unrecognised `/cmd`) — forwarded to the
  server as chat, so server-side commands work without the client
  knowing them. `//foo` sends the literal text `/foo` as chat.

Arrow keys browse command history (persists at `~/.heidrun_history`);
TAB completes builtin command names (single match splices, multiple
match dumps the list, no-match no-op); the connection auto-reconnects
on disconnect with capped exponential backoff (1/2/4/8/16/30/30/30s,
8 attempts).

## Protocol extensions

Heidrun layers a few non-standard extensions on top of base Hotline (e.g. emoji
user avatars). They're additive and degrade gracefully to standard behaviour.
The wire layouts are specified in [`docs/PROTOCOL-EXTENSIONS.md`](docs/PROTOCOL-EXTENSIONS.md).

## Using it

```swift
// Package.swift
dependencies: [
    .package(url: "git@github.com:franckjej/heidrun-protocol.git", from: "1.0.0")
]

// in a target's dependencies:
.product(name: "HeidrunCore", package: "heidrun-protocol")
```

The repo is private — clone with SSH or a `gh auth`-cached HTTPS
credential.

## Building

```bash
swift build
swift test
```

The HeidrunTestServer side-tool is a separate package; build it with:

```bash
cd HeidrunTestServer
swift run HeidrunTestServer
```

## Wire-protocol gotchas

(See `CLAUDE.md` in the consumer repos for the longer treatment.)

- All multi-byte ints are big-endian.
- String encoding defaults to `.macOSRoman`; overridable.
- Login + password obfuscation = XOR every byte with `0xFF` on the
  classic login (transID 107) + most account-admin transactions —
  **but not** on `openLogin` (352), where login goes plain.
- Path encoding (objIDs 202, 212, 325): `UInt16 componentCount`
  followed by per-component `(UInt16 0 pad, UInt8 length, name)`.
- HTXF handshake variants: file download = `"HTXF"` + UInt32
  transferID + UInt32 transferSize + UInt32 reserved (0); folder
  upload swaps the trailing 4 bytes for `UInt16 1, 0`; folder
  download is 18 bytes with a `UInt16 3` sentinel.
- Hotline timestamps are seconds since `1904-01-01 00:00:00 UTC`
  (classic Mac epoch). See `HotlineDate` and
  `UploadFraming.secondsSince1904`.
- File upload framing: `FILP` 40-byte header (forkCount=3) → `INFO`
  block (74 + nameLen) with HFS type/creator + 1904-epoch dates +
  name → `DATA` fork hdr (16B) + data fork → `MACR` fork hdr (16B;
  resource fork is empty in this implementation).

## License

Released publicly under the **GNU General Public License v2.0**. Full
text in `LICENSE` at the repository root, or at
<https://www.gnu.org/licenses/gpl-2.0.html>.

The GPL-2.0 release aligns this package with the public licensing of
[`heidrun-swift`][heidrun-swift] — the macOS client is a port of the
2002 Heidrun Hotline client by Göran Granström, whose original
plug-in modules were GPL-2.0; this package shares that lineage out of
respect for the same heritage. See `NOTICE.md` in the heidrun-swift
repository for the full credit.

### Dual licensing

Copyright © Daubit & Francke GmbH. **The copyright holder reserves all
rights to license this code under other terms** — commercial,
proprietary, BSD/MIT-style, or any other arrangement — for its own
products (notably the closed-source operator side of HeidrunServer)
and for third parties on request. The GPL-2.0 grant above governs
public/community use; it does not bind the copyright holder's own
re-use of the same code under different terms.

If you'd like a non-GPL license for this package, get in touch:
`jens.francke@daubit-francke.de`.

### Third-party dependencies

This package links the following Apple Swift open-source packages,
each distributed under the **Apache License 2.0**:

- `swift-nio` — https://github.com/apple/swift-nio
- `swift-argument-parser` — https://github.com/apple/swift-argument-parser

Plus the transitive `swift-atomics`, `swift-collections`,
`swift-system` (all Apache 2.0). Their license texts ship with the
binary distribution of `heidrun-swift` (see that repo's
`THIRD_PARTY_LICENSES.md`).

[heidrun-swift]: https://github.com/franckjej/heidrun-swift
[heidrun-server]: https://github.com/franckjej/heidrun-server
