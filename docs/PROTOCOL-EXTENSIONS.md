# Heidrun protocol extensions

This document specifies the **non-standard extensions** Heidrun layers on top
of the classic Hotline protocol. It does **not** re-document base Hotline
(transactions, the 20-byte packet header, the TLV field encoding, the HTXF
transfer side-channel) — for those, read the source: `HotlineObjectKey.swift`,
`InfoTransaction.swift`, `TransactionType.swift`, and the per-codec doc comments
in `Sources/HeidrunCore/Network/`.

Everything here is additive and **degrades gracefully**: a Heidrun extension
only "lights up" when a Heidrun client talks to a Heidrun server. Legacy clients,
and any third-party server that doesn't understand an extension, fall back to
standard behaviour with no errors.

Audience: anyone implementing a compatible client or server (the extensions are
deliberately simple so other implementations can adopt them).

---

## Conventions

- **Byte order:** big-endian, like all multi-byte integers in base Hotline.
- **`u_int16` / `u_int8`:** unsigned 16-bit / 8-bit, as in the original
  `HeiHLTypes.h` struct definitions.
- **Object IDs** ("field keys") tag fields inside a transaction's TLV payload.
- Field keys cited below are the values of `HotlineObjectKey` raw cases.

---

## The Heidrun extension field band (`0xE000`+)

Standard Hotline field keys are small integers (base Hotline and the dialects
Heidrun implements stay well under `0x0400`). To carry vendor-specific fields
without colliding with the standard set — present or future — Heidrun reserves a
high band starting at:

```
0xE000   (57344)   first Heidrun extension field key
```

`0xE000` is the start of the Unicode BMP Private-Use Area, chosen as a mnemonic
("private use") and because no known Hotline implementation allocates field keys
that high. New Heidrun extension fields append upward from here.

A receiver that doesn't recognise a field key in this band **must skip it**
(base Hotline's TLV framing is length-prefixed, so unknown fields are skipped
naturally). This is what makes the extensions safe to send to any peer.

| Field key | Name        | Type        | Since            |
|-----------|-------------|-------------|------------------|
| `0xE000`  | `userEmoji` | UTF-8 string | protocol rc7 / server rc5 |
| `0xE001`  | `errorKind` | `UInt16`    | protocol rc12 |
| `0xE002`  | `resourceForkSupport` | `UInt8` (= 1) | protocol rc14 / server tbd (2026-06) |

---

## `userEmoji` — emoji user avatars

Lets a user choose a **real emoji** as their avatar in place of (or as an
override for) the numeric Hotline icon (object `104`). The numeric icon is
**always still sent**, so any peer that ignores `userEmoji` shows a normal icon.

### Field

```
key:   0xE000  (userEmoji)
value: a UTF-8 string holding a single emoji grapheme cluster
```

**Encoding is always UTF-8**, independent of the connection's negotiated string
encoding (which defaults to Mac OS Roman and cannot represent emoji). This
applies in **both** directions and in every transaction below. An empty value
means "no emoji".

### Where it travels

`userEmoji` rides alongside the existing nickname/icon fields. It is a TLV field
everywhere except the bulk user-list reply, which is a packed binary blob (see
below).

**Client → server**

| Transaction | ID  | `userEmoji` presence |
|-------------|-----|----------------------|
| `login`             | 107 | Present only when the user has an emoji set; **omitted** otherwise. |
| `agreeToAgreement`  | 121 | Same rule as login (optional). |
| `setClientUserInfo` (a.k.a. changeNickname) | 304 | **Always present.** A non-empty value sets the emoji; an **empty string clears** it. |

The 304 rule is deliberate: because that transaction carries the user's full
runtime identity, the server cannot otherwise distinguish "emoji unchanged" from
"emoji cleared". Always sending the field (empty == cleared) removes the
ambiguity. login/agree omit it because a fresh session has nothing to clear.

**Server → clients**

| Transaction | ID  | How `userEmoji` is carried |
|-------------|-----|----------------------------|
| `userChanged` (push) | 301 | TLV field `0xE000`. |
| `getClientInfoText` reply | 303 | TLV field `0xE000`. |
| `getUserList` reply  | 300 | **Appended to the packed `userListEntry` blob** (see below). |

The server stores the emoji per session (set on login/304) and echoes it
wherever it reports a user's icon.

### User-list entry blob (object `300`) — trailing emoji block

Each user in a `getUserList` reply is a packed `userListEntry` object. Heidrun
**appends an optional emoji block after the nickname**:

```
u_int16  socket
u_int16  icon
u_int16  status            // colour byte + flags byte
u_int16  nickLength
u_int8   nick[nickLength]
--- Heidrun extension (optional; absent on legacy entries / no emoji) ---
u_int16  emojiByteLength   // 0 or block absent  => no emoji
u_int8   emoji[emojiByteLength]   // UTF-8
```

Backward compatibility rests on this being a **trailing** block:

- **Encoder:** append the `emojiByteLength + emoji` block only when the user has
  a non-empty emoji. Otherwise emit exactly the classic layout.
- **Decoder:** after reading the nickname, read the block **only if at least 2
  bytes remain**. `emojiByteLength == 0` (or no remaining bytes) means no emoji.
  A legacy decoder that stops after the nickname simply ignores the extra bytes.

This is the only place `userEmoji` is **not** a TLV field — the `userListEntry`
object is a fixed binary structure in base Hotline, so the extension extends the
structure rather than adding a sibling field.

### Receiver guidance (rendering)

`userEmoji` is a free string on the wire, so a hostile or buggy peer could send
arbitrary text. Before rendering, a client **should**:

1. Take only the **first grapheme cluster** of the value.
2. Reject values longer than a small byte cap (**Heidrun uses 64 bytes** — large
   enough for the longest standard ZWJ emoji like 👨‍👩‍👧‍👦, small enough to
   bound abuse).
3. Treat empty / whitespace-only as "no emoji" and fall back to the numeric icon.

The reference implementation is `HeidrunUI.EmojiAvatar.sanitized(_:)` in the
client. Worst case a malicious value renders as a single stray glyph, never a
wall of text.

### Compatibility matrix

| Sender client | Server      | Viewer client | Result |
|---------------|-------------|---------------|--------|
| Heidrun       | Heidrun     | Heidrun       | ✅ emoji rendered |
| Heidrun       | Heidrun     | legacy        | legacy ignores the field / trailing bytes → numeric icon |
| Heidrun       | third-party | Heidrun       | server drops the field → numeric icon everywhere |
| legacy        | Heidrun     | Heidrun       | sender has no emoji → numeric icon |

In every non-✅ row the user still sees a valid avatar, because the numeric icon
field (object `104`) is always sent.

### Single-avatar convention (client UX, informative)

Not a wire requirement, but the behaviour Heidrun's own client implements so
other clients can match it: the user picks **either** a numeric icon **or** an
emoji. Choosing an emoji keeps the last numeric icon as the silent
degradation fallback (still sent); choosing a bundled icon clears the emoji.
Live identity changes send the icon and emoji together (via 304) so changing one
never clears the other unintentionally.

---

## `resourceForkSupport` — framed single-file downloads

Capability flag advertising that an endpoint supports the FILP/INFO/DATA/MACR
envelope on **single-file downloads** (TX 202). When both peers send it, the
side channel for a single-file download ships the framed envelope and the
resource fork survives end-to-end. When either side omits it, the side channel
falls back to **raw data-fork bytes** — the classic Heidrun dialect — and the
resource fork can't be carried (use a one-item folder download for that case).

### Field

```
key:   0xE002  (resourceForkSupport)
value: UInt8 == 1
```

The single-byte value is `1` whenever present; future flags can be packed into
extra bits if the need arises. A receiver that finds any other value should
treat it as "not supported".

### Where it travels

**Client → server**

| Transaction | ID  | `resourceForkSupport` presence |
|-------------|-----|--------------------------------|
| `login`             | 107 | Send when the client can parse the framed envelope on download; omit otherwise. |
| `agreeToAgreement`  | 121 | Same rule as login. |

**Server → client**

| Transaction | ID  | `resourceForkSupport` presence |
|-------------|-----|--------------------------------|
| `login` reply       | 107 | Server **echoes the field iff** it received it AND it can produce the framed envelope. The echo is the negotiated handshake. |

A session is "framed" only when the server echoes the field back on the login
reply. Without the echo the client must read the download side channel as raw
bytes (the historical Heidrun dialect).

### Wire effect when negotiated

On a successful TX 202 (`downloadFile`):

1. The reply's `transferSize` is the **whole envelope length** computed by
   `UploadFraming.totalSize(nameLength:dataLength:resourceLength:)`, not just
   the data-fork length.
2. The HTXF side channel carries the standard 16-byte preamble followed by the
   FILP+INFO+DATA+resource-fork+MACR bytes the same encoder produces for
   uploads. The decoder (`UploadFraming.decode`) is symmetric.

When **not** negotiated, the side channel after the preamble is the raw data
fork from the requested offset onwards — byte-for-byte identical to the
pre-extension behaviour, so legacy clients keep working with no change.

### Compatibility matrix

| Sender client | Server      | Result |
|---------------|-------------|--------|
| Heidrun (sends 0xE002) | Heidrun (echoes 0xE002) | ✅ framed single-file downloads; resource fork carried |
| Heidrun       | legacy / non-echoing | client sees no echo → expects raw bytes → no resource fork (same as today) |
| legacy        | Heidrun     | server sees no flag → server emits raw bytes → no resource fork (same as today) |
| legacy        | legacy      | unchanged |

In every row the data fork still arrives correctly; only the resource fork is
gated on the negotiation.

---

## `largeFiles` — 64-bit transfers (> 4 GiB)

Base Hotline caps every file size, transfer length, and offset at a 32-bit
field — a hard **4 GiB ceiling**. This extension lifts it. Unlike the other
entries here it is **not** a Heidrun (`0xE000`-band) invention: it adopts the
**fogWraith capability scheme** (`github.com/fogWraith/Hotline`, `DATA_CAPABILITIES`
bit 0), so a Heidrun client interoperates with other modern implementations
(e.g. gtkhx) that speak the same dialect. It is purely additive: both the legacy
32-bit and the new 64-bit fields travel together, so any peer that ignores the
64-bit fields still sees a (clamped) 32-bit value.

### Capability negotiation — `DATA_CAPABILITIES` (`0x01F0`)

A big-endian `UInt16` **bitmask** carried in `login` (107). The client advertises
the bits it supports; the server echoes back **only** the bits it enables for the
session (the intersection). Large files are on for the session iff bit 0 survives
the round-trip.

```
key:   0x01F0  (capabilities)
value: UInt16 bitmask, bit 0 = CAPABILITY_LARGE_FILES (0x0001)
```

Other fogWraith bits (`textEncoding 0x0002`, `voice 0x0004`, `inlineMedia 0x0008`,
`chatHistory 0x0010`, `extendedPriv 0x0020`) are **reserved, not implemented** by
Heidrun. This `0x01F0` channel is separate from Heidrun's `0xE000` band and from
`resourceForkSupport` (`0xE002`) — they coexist and are negotiated independently.

### 64-bit companion fields

When large-file mode is active, replies carry these **alongside** the legacy
32-bit fields (which clamp to `0xFFFFFFFF`):

| Field key | Name | Type | Carried in |
|-----------|------|------|------------|
| `0x01F1` | `fileSize64` | `UInt64` | file list (200), get-info (206) |
| `0x01F2` | `offset64` | `UInt64` | download request (resume offset) |
| `0x01F3` | `xferSize64` | `UInt64` | download reply (202), upload request (203) |
| `0x01F4` | `folderItemCount64` | `UInt64` | reserved — folder transfers not yet 64-bit |

In **Get File Name List** (200) each `fileSize64` is a **separate field appended
after** its `fileListEntry` blob (the in-blob 32-bit size clamps); a decoder pairs
each entry with the immediately-following `fileSize64`.

### HTXF handshake — 24-byte variant

The HTXF side-channel preamble grows from 16 to 24 bytes. The previously-reserved
bytes 12–15 become a flags word; an 8-byte length follows when `SIZE64` is set:

```
[0..3]   "HTXF"
[4..7]   UInt32 transferID
[8..11]  UInt32 legacy length   (set to 0 when the true length > 0xFFFFFFFF)
[12..15] UInt32 flags           (HTXF_FLAG_LARGE_FILE 0x1 | HTXF_FLAG_SIZE64 0x2)
[16..23] UInt64 length          (present only when SIZE64 is set)
```

A 16-byte preamble (no `SIZE64`) is exactly the legacy handshake — byte-identical,
so legacy transfers are unchanged. A receiver reads the 16-byte head, and only
reads 8 more bytes when `SIZE64` is set in the flags word.

### FFO fork headers — 64-bit length

The 16-byte FILP/INFO/**DATA**/**MACR** fork header carries a 64-bit fork length by
splitting it across the two length slots — **high 32 bits at offset 4–7** (the
first reserved word), **low 32 bits at offset 12–15**:

```
[0..3]   fork magic ("DATA" / "MACR")
[4..7]   UInt32 high32(length)
[8..11]  4 reserved/zero bytes
[12..15] UInt32 low32(length)        →  length = (high << 32) | low
```

For files ≤ 4 GiB the high word is zero, so the bytes are **identical** to the
historical 32-bit-only header. This is how a framed (resource-fork) single-file
download of a > 4 GiB file round-trips.

### Affected transactions and modes

| Transaction | ID | Large-file behaviour |
|-------------|----|----------------------|
| `login` | 107 | negotiate `0x01F0` |
| Get File Name List | 200 | append `fileSize64` per entry |
| Download File | 202 | 64-bit reply size + 24-byte HTXF; framed envelope uses 64-bit fork headers |
| Upload File | 203 | client sends `xferSize64`; **> 4 GiB uploads ship the raw data fork** (no FILP/INFO/DATA/MACR wrapper) — so a > 4 GiB upload is **data-fork only** (no resource fork) |
| Get File Info | 206 | append `fileSize64` |

Resume offsets > 4 GiB ride `offset64` (`0x01F2`); the legacy `fileResumeInfo`
structure stays 32-bit. **Folder** transfers (210 / 213) are 64-bit as of rc30:
the folder stream's per-item size prefix widens to 8 bytes (UInt64) when the
session negotiated large files (4 bytes otherwise), and the reply/request carry
`xferSize64`. The per-folder **item count** stays `UInt16` (max 65,535 items);
`folderItemCount64` (`0x01F4`) is reserved for lifting that later.

### Compatibility matrix

| Client | Server | Result |
|--------|--------|--------|
| sends `0x01F0` bit 0 | echoes bit 0 | ✅ > 4 GiB transfers; both 32+64-bit fields sent |
| sends bit 0 | no echo | client stays 32-bit; > 4 GiB refused client-side (can't be represented) |
| no `0x01F0` | sends 64-bit fields | client ignores them, reads the clamped 32-bit value |
| legacy | legacy | unchanged |

---

## `textEncoding` — UTF-8 strings

Negotiates **UTF-8** for all human-readable strings (chat, nicknames, file/folder
names, comments, news, errors, chat topic) in place of macOS Roman. Like
`largeFiles`, it rides the fogWraith `0x01F0` capability bitmask (so it
interoperates with the modern ecosystem, e.g. gtkhx), and degrades to macOS Roman
with any peer that doesn't echo it.

### Negotiation

```
key:   0x01F0  (capabilities)
value: UInt16 bitmask, bit 1 = CAPABILITY_TEXT_ENCODING (0x0002)
```

Advertised in `login` (107), echoed by the server in the reply when enabled.

### When the flip takes effect

The encoding flips to UTF-8 for **all traffic after the login reply**. The login
request *and the login reply itself* stay macOS Roman on both sides (so they're
consistent and ASCII-safe). The flip is applied at three actor-isolated points:
the engine's inbound decode flips when it processes a reply carrying the bit
(serial dispatch → no race); each client's outbound encoding flips after reading
the reply; the server flips after sending the reply.

### The login nickname (the one special case)

The capability is negotiated *in* the login packet, so the login's own display
string — the **nickname** — is special-cased: it is encoded **UTF-8 when the
client advertises `textEncoding` in that same login packet**, and the server
decodes it as UTF-8 when the login packet's caps include the bit. (This keeps the
nick in login — the server's audit log, roster, and `userChanged` broadcast all
see the real nick immediately — rather than deferring it to a post-login TX 304.)
`login`/`password` remain XOR-0xFF credential bytes (encoding-agnostic); `emoji`
is always UTF-8 regardless.

### Broadcasts (current limitation)

Broadcasts (chat, `userChanged`, news, topic) are encoded once with the
broadcasting session's encoding and delivered to all recipients. This is fully
correct when every connected client negotiated UTF-8 (the all-Heidrun case). In a
**mixed** population — a legacy macOS-Roman client present alongside UTF-8 clients
— non-ASCII broadcast content can mis-render for the peer whose encoding differs
from the broadcaster's (graceful mojibake, never a crash). Per-recipient broadcast
encoding is a future refinement.

### Compatibility matrix

| Client | Server | Result |
|--------|--------|--------|
| sends `0x01F0` bit 1 | echoes bit 1 | ✅ UTF-8 for all strings post-login; login nick UTF-8 |
| sends bit 1 | no echo | session stays macOS Roman; client's login nick was UTF-8 but a non-cap server may mojibake a non-ASCII login nick (ASCII fine) |
| no `0x01F0` | — | macOS Roman everywhere, byte-identical to legacy |

---

## Versioning

| Extension   | Introduced |
|-------------|------------|
| `0xE000` field band, `userEmoji` | `heidrun-protocol` **v1.0.0-rc7**, `heidrun-server` **v1.0.0-rc5** (2026-05) |
| `0xE002` `resourceForkSupport`   | `heidrun-protocol` **v1.0.0-rc14** (2026-06), `heidrun-server` next rc |
| `largeFiles` (`0x01F0`–`0x01F4`, 24-byte HTXF, 64-bit fork headers) | `heidrun-protocol` **v1.0.0-rc27**, `heidrun-server` **v1.0.0** (server build pinned rc28), client pinned rc29 (2026-06). rc28 = > 4 GiB framed-download fix; rc29 = `largeFilesEnabled` on the client protocol surface |
| `largeFiles` — folder transfers (210 / 213, gated 8-byte item prefix, `xferSize64`) | `heidrun-protocol` **v1.0.0-rc30** (2026-06); server + client pinned rc30 |
| `textEncoding` (`0x01F0` bit 1, UTF-8, login-nick special case, 3-actor flip) | `heidrun-protocol` **v1.0.0-rc32**, server + client pinned rc32 (2026-06). (rc31 was a superseded variant that moved the nick to a post-login TX 304.) |

When adding a new **Heidrun** extension: append a field key in the `0xE000` band,
document it here with its wire layout, keep it additive (omittable / trailing),
and make sure a peer that ignores it still gets correct standard behaviour.
Adopted external extensions (like `largeFiles`) follow their upstream namespace
instead of the `0xE000` band — note that explicitly, as above.
