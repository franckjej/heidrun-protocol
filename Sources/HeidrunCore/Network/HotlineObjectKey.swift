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
