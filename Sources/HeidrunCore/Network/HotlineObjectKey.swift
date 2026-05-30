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
