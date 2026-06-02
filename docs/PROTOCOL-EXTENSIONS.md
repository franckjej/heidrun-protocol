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

## Versioning

| Extension   | Introduced |
|-------------|------------|
| `0xE000` field band, `userEmoji` | `heidrun-protocol` **v1.0.0-rc7**, `heidrun-server` **v1.0.0-rc5** (2026-05) |
| `0xE002` `resourceForkSupport`   | `heidrun-protocol` **v1.0.0-rc14** (2026-06), `heidrun-server` next rc |

When adding a new extension: append a field key in the `0xE000` band, document
it here with its wire layout, keep it additive (omittable / trailing), and make
sure a peer that ignores it still gets correct standard behaviour.
