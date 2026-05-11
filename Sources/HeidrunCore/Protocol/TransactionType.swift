/// Identifies the kind of Hotline transaction issued by the client.
///
/// Values come straight from the original `HeiSendingProtocol.h` enum that
/// `HeiTaskObject` carried in its `taskType` field. Reply transactions
/// carry server-side answers that Heidrun expects to match against pending
/// requests; "no-reply" transactions are fire-and-forget commands.
public enum TransactionType: Int, Sendable, CaseIterable {
    case replyGetUserList = 1
    case replyGetNewsList
    case replyGetUserInfo
    case replyLoginTask
    case replyPostNewNews
    case replyBroadcastMsg
    case replyKickUser
    case replySendPrivMsg
    case replyCreatePChat
    case replyJoinPChat
    case replyOpenUser
    case replyGetNewsBundle
    case replyGetNewsCategory
    case replyGetNewsThread
    case replyGetFilesPath
    case replyDownloadFile
    case replyUploadFile
    case replyGetFileInfo
    case replyDownloadFolder
    case replyUploadFolder

    case noReplyAgreeAgreement
    case noReply185Ping
    case noReplySendChat
    case noReplyChangeNick
    case noReplyRejectPC
    case noReplyCreateLogin
    case noReplyLeavePC
    case noReplyAddToPChat
    case noReplyDeleteLogin
    case noReplyModifyLogin
    case noReplyChangeSubject
    case noReplyRemoveTNews
    case noReplyCreateTNews
    case noReplyRemoveTNewsThread
    case noReplyPostTNewsThread
    case noReplyRemoveFilePath
    case noReplyCreatePath
    case noReplySetPathInfo
    case noReplyMovePath
    case noReplyMakeAlias

    /// `true` when the server is expected to respond to this transaction.
    public var expectsReply: Bool {
        rawValue <= TransactionType.replyUploadFolder.rawValue
    }
}
