/// 16-bit object IDs the Hotline protocol uses to tag fields inside a
/// transaction's TLV payload.
///
/// Values transcribed from `HEClientReceive.m` / `HEClient.m`. Names follow
/// Swift conventions; the original Objective-C used C-string keys like
/// `kErrorMsgStr`/`kSocketStr`.
public enum HotlineObjectKey: UInt16, Sendable, Hashable, CaseIterable {
    case errorMessage    = 100
    case message         = 101
    case nickname        = 102
    case socket          = 103
    case icon            = 104
    case login           = 105   // bit-inverted on the wire
    case password        = 106   // bit-inverted on the wire
    case transferID      = 107
    case transferSize    = 108
    case parameter       = 109
    case privileges      = 110
    case status          = 112
    case banFlag         = 113
    case chatReference   = 114   // 4 bytes
    case chatSubject     = 115
    case transferQueue   = 116
    /// Server-banner format hint, sent alongside the 212 reply when
    /// the operator supplies one. Values per the Hotline spec:
    /// 1 = URL, 3 = JPEG, 4 = GIF, 5 = BMP, 6 = PICT.
    case bannerType      = 152
    case autoAgree       = 154
    case clientVersion   = 160
    case serverName      = 162

    case fileListEntry      = 200
    case fileName           = 201
    case filePath           = 202
    case fileResumeInfo     = 203
    case folderResumeFlag   = 204   // folder-upload resume marker (UInt16 = 1)
    case longFileType       = 205
    case longFileCreator    = 206
    case fileSize           = 207
    case fileCreationDate   = 208
    case fileModificationDate = 209
    case fileComment        = 210
    case fileRename         = 211
    case destinationPath    = 212
    case folderItemCount    = 220   // upload-folder reply / request (UInt16)

    /// **Heidrun extension** (CAPABILITY_LARGE_FILES). UInt16 bitmask of
    /// negotiated protocol capabilities (see `CapabilityFlags`).
    case capabilities       = 0x01F0

    /// **Heidrun extension** (CAPABILITY_LARGE_FILES). 64-bit file size,
    /// sent alongside the legacy 32-bit `fileSize` (207) in a file-list
    /// entry so large files (> 4 GiB) report their true size.
    case fileSize64         = 0x01F1

    /// **Heidrun extension** (CAPABILITY_LARGE_FILES). 64-bit resume
    /// offset for large-file transfers.
    case offset64           = 0x01F2

    /// **Heidrun extension** (CAPABILITY_LARGE_FILES). 64-bit transfer
    /// size for large-file transfers.
    case xferSize64         = 0x01F3

    /// **Heidrun extension** (CAPABILITY_LARGE_FILES). Reserved — 64-bit
    /// folder item count (not yet implemented).
    case folderItemCount64  = 0x01F4

    case userListEntry      = 300

    /// **Heidrun extension** (not standard Hotline). A UTF-8 emoji the
    /// user picked as their avatar, sent alongside the numeric `icon` on
    /// login (107) / agree (121) / changeNickname (304) and appended to the
    /// user-list entry (300). `0xE000` is the base of the Heidrun extension
    /// band, well clear of standard Hotline keys. Always UTF-8, never the
    /// connection's `stringEncoding`.
    case userEmoji          = 0xE000

    /// **Heidrun extension** (not standard Hotline). UInt16 kind code
    /// attached to an error reply (header.errorID != 0) so the client
    /// can switch on the failure mode programmatically rather than
    /// parsing the human-readable `.errorMessage`. Values are defined
    /// in `HotlineErrorKind`. Absent on errors that don't have a
    /// specific kind — clients fall back to the generic server-error
    /// case in that situation.
    case errorKind          = 0xE001

    /// **Heidrun extension** (not standard Hotline). Single-byte capability
    /// flag (`UInt8 == 1`) exchanged on TX 107 login and TX 121 agree.
    /// When **both** endpoints send it the negotiated session uses
    /// FILP/INFO/DATA/MACR framing on single-file downloads (so the
    /// resource fork rides through end-to-end); when either side omits
    /// it the side channel falls back to raw data-fork bytes — the
    /// classic Heidrun dialect. Symmetric on request and reply.
    case resourceForkSupport = 0xE002

    // Threaded news
    case newsThreadList     = 321
    case newsCategoryName   = 322
    case newsBundleEntry    = 323
    case newsPath           = 325
    case newsArticleID      = 326
    case newsType           = 327
    case newsTitle          = 328
    case newsAuthor         = 329
    case newsDate           = 330
    case newsPrevThread     = 331
    case newsNextThread     = 332
    case newsData           = 333
    case newsArticleFlags   = 334
    case newsParentThread   = 335
    case newsReplyThread    = 336
    case newsDeleteAll      = 337
}
