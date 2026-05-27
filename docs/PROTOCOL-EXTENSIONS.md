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

## Versioning

| Extension   | Introduced |
|-------------|------------|
| `0xE000` field band, `userEmoji` | `heidrun-protocol` **v1.0.0-rc7**, `heidrun-server` **v1.0.0-rc5** (2026-05) |

When adding a new extension: append a field key in the `0xE000` band, document
it here with its wire layout, keep it additive (omittable / trailing), and make
sure a peer that ignores it still gets correct standard behaviour.
