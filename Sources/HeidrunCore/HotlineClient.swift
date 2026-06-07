import Foundation

/// Connection-level metadata exposed to anyone holding a `HotlineClient`.
public struct HotlineConnectionInfo: Sendable, Hashable {
    /// Heidrun's own client version, mirrored back to the server.
    public var clientVersion: Int

    /// Hotline protocol version the connection negotiated.
    public var protocolVersion: Int

    /// Version the server reported in its login reply. Zero when the server
    /// didn't include one (typical for Wired Client / non-Hotline servers).
    /// Hotline encodes versions as flat integers: 150 = 1.5.0, 185 = 1.8.5.
    public var serverVersion: Int

    /// Server-assigned socket / user id for this connection.
    public var connectionSocket: UInt16

    /// The most recent task number the client used.
    public var lastTaskNumber: UInt32

    /// The settings the user picked when they opened this connection.
    public var settings: ConnectionSettings

    /// The most recent public/main chat topic the server pushed
    /// (TX 119 `NotifyChatSubject` with Chat ID 0). Empty when the
    /// server hasn't set one. Recorded by the read loop regardless of
    /// whether a UI subscriber was listening — so a view that starts
    /// observing after the login-time push can still seed its header.
    public var publicChatSubject: String

    /// The connected account's own access privileges, as last pushed by the
    /// server via "User Access" (TX 354). Empty until the server sends it
    /// (or for servers that never do). A UI hint for disabling controls —
    /// the server still enforces every privilege per request. Recorded by
    /// the read loop so a view that starts observing after the login-time
    /// push can still seed its gating.
    public var privileges: UserPrivileges

    public init(
        clientVersion: Int,
        protocolVersion: Int,
        serverVersion: Int = 0,
        connectionSocket: UInt16,
        lastTaskNumber: UInt32,
        settings: ConnectionSettings,
        publicChatSubject: String = "",
        privileges: UserPrivileges = []
    ) {
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion
        self.serverVersion = serverVersion
        self.connectionSocket = connectionSocket
        self.lastTaskNumber = lastTaskNumber
        self.settings = settings
        self.publicChatSubject = publicChatSubject
        self.privileges = privileges
    }
}

/// Extended profile a server returns from "get user info".
///
/// The wire-level payload is the core `User`, the account login name the
/// peer authenticated as (field 105), and a free-form info string the
/// user wrote into their profile pane (field 101). The legacy
/// Objective-C client stuffed all three into an `NSDictionary`; here
/// they're explicit so the call site reads at a glance.
///
/// `accountLogin` may be empty if the server omits field 105 — most
/// modern Hotline servers send it, but guest-only setups sometimes
/// don't, so the sheet should treat empty as "not provided" rather
/// than as an error.
public struct UserInfo: Sendable, Hashable {
    public var user: User
    public var accountLogin: String
    public var infoText: String

    public init(user: User, accountLogin: String = "", infoText: String) {
        self.user = user
        self.accountLogin = accountLogin
        self.infoText = infoText
    }
}

/// Extended file or folder details returned by "get path info".
public struct RemoteFileInfo: Sendable, Hashable {
    public var file: RemoteFile
    public var creationDate: Date?
    public var modificationDate: Date?
    public var comment: String?
    public var dataForkSize: UInt32
    public var resourceForkSize: UInt32

    public init(
        file: RemoteFile,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        comment: String? = nil,
        dataForkSize: UInt32 = 0,
        resourceForkSize: UInt32 = 0
    ) {
        self.file = file
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.comment = comment
        self.dataForkSize = dataForkSize
        self.resourceForkSize = resourceForkSize
    }
}

/// Handle returned when starting an outbound or inbound transfer.
public struct TransferHandle: Sendable, Hashable, Identifiable {
    /// Server-assigned transfer ID; unique per connection.
    public let transferID: UInt32

    /// Total bytes the server expects to send / receive.
    public let totalSize: UInt64

    /// `true` when the side channel for this transfer ships the FILP
    /// envelope (data fork + resource fork + metadata) rather than raw
    /// data-fork bytes. Set by `startDownload(...)` when the session
    /// negotiated `resourceForkSupport`. `downloadStream(for:)` reads
    /// this to transparently extract the data fork; `downloadEnvelope`
    /// requires `framed == true`.
    public let framed: Bool

    public init(transferID: UInt32, totalSize: UInt64, framed: Bool = false) {
        self.transferID = transferID
        self.totalSize = totalSize
        self.framed = framed
    }

    public var id: UInt32 { transferID }
}

/// Differentiates the two flavours of the data that "set path info" carries.
public enum FileMetadataChange: Sendable, Hashable {
    case rename(newName: String)
    case comment(newComment: String)
}

/// Async, typed replacement for the original Objective-C
/// `HeiSendingMethods` protocol from `HeiSendingProtocol.h`.
///
/// Each operation is `async throws`: success returns the typed result,
/// failure throws `HotlineError`. Server-pushed events are delivered through
/// `events`, an `AsyncStream` callers can iterate with `for await`.
///
/// The protocol is split topically; conforming types implement everything in
/// one place but readers see related operations grouped.
public protocol HotlineClient: Sendable {

    // MARK: Connection metadata

    /// Live connection details. Read-only from the client's perspective.
    var connectionInfo: HotlineConnectionInfo { get async }

    /// Server-pushed events: chat lines, user-list updates, broadcasts.
    /// Multiple subscribers are supported.
    var events: AsyncStream<HotlineEvent> { get }

    /// Drop the TCP connection. Always clean — the connection is gone after
    /// this returns whether the server replied or not.
    func disconnect() async

    /// Ask the host UI to bring attention to this connection. Maps onto the
    /// original `requestAttentionOfType:module:` helper.
    func requestAttention(_ flags: AttentionFlags) async

    // MARK: Authentication & presence

    /// Send the protocol-defined keep-alive ping (transaction 185).
    func sendPing() async throws

    /// Authenticate against the server. `emoji` is a Heidrun extension —
    /// an optional UTF-8 emoji avatar sent alongside the numeric `icon`.
    func login(
        name: String,
        password: String,
        nickname: String,
        icon: UInt16,
        emoji: String?
    ) async throws

    /// Acknowledge the server's agreement banner.
    func agreeToAgreement(nickname: String, icon: UInt16, emoji: String?) async throws

    /// Update our own profile in the user list. `emoji` (Heidrun extension)
    /// is always sent: a value sets it, an empty string clears it.
    func changeNickname(
        _ nickname: String,
        icon: UInt16,
        emoji: String?,
        persist: Bool
    ) async throws

    // MARK: User list

    /// Fetch the current user list.
    func fetchUserList() async throws -> [User]

    /// Fetch one user's extended info.
    func fetchUserInfo(socket: UInt16) async throws -> UserInfo

    /// Disconnect another user. `ban == true` adds them to the server's ban
    /// list when supported.
    func kick(socket: UInt16, ban: Bool) async throws

    // MARK: Plain news (legacy bulletin-board style)

    /// Fetch the legacy plain news feed.
    func fetchNewsFeed() async throws -> String

    /// Append a new post to the legacy feed.
    func postPlainNews(_ text: String) async throws

    // MARK: Direct messages

    /// Send a server-wide broadcast (admin-only on most servers).
    func broadcast(_ message: String) async throws

    /// Send a private message to one user.
    func sendPrivateMessage(_ message: String, to socket: UInt16) async throws

    // MARK: Public & private chat

    /// Send a chat line. Pass `nil` for `chat` to target the public chat;
    /// supply a `ChatID` to target a private chat room. `isAction == true`
    /// formats as a `/me` style action line.
    func sendChat(
        _ message: String,
        in chat: ChatID?,
        isAction: Bool
    ) async throws

    /// Open a private chat with another user.
    func createPrivateChat(with socket: UInt16) async throws -> ChatID

    /// Accept an invitation to a private chat.
    func joinPrivateChat(_ chat: ChatID) async throws

    /// Decline an invitation to a private chat.
    func rejectPrivateChat(_ chat: ChatID) async throws

    /// Leave a private chat we're in.
    func leavePrivateChat(_ chat: ChatID) async throws

    /// Change a private chat room's subject.
    func changeChatSubject(_ subject: String, in chat: ChatID) async throws

    /// Invite another user into a private chat we're in.
    func invite(socket: UInt16, to chat: ChatID) async throws

    // MARK: Account administration

    /// Create a new server-side login. Caller-side validation is the
    /// responsibility of the UI; the server enforces final policy.
    func createLogin(
        name: String,
        password: String,
        nickname: String,
        privileges: UserPrivileges
    ) async throws

    /// Delete an existing server-side login.
    func deleteLogin(_ name: String) async throws

    /// Open an existing login for editing. The reply contains the current
    /// nickname and privileges.
    func openLogin(_ name: String) async throws -> (nickname: String, privileges: UserPrivileges)

    /// Modify an existing login. Pass `password == nil` to leave the password
    /// unchanged (mirrors the original `noPass` flag).
    func modifyLogin(
        name: String,
        password: String?,
        nickname: String,
        privileges: UserPrivileges
    ) async throws

    // MARK: Threaded news

    /// List the folders and categories at a path. Send-side mapping is
    /// transID 370 (`getTNewsPath:category:NO`). Use this when the path
    /// points at a bundle (folder); for a category's contents call
    /// `fetchNewsThreads(at:)` instead.
    func fetchNewsBundles(at path: RemotePath) async throws -> [NewsBundle]

    /// Fetch the threads (posts) inside a category. Send-side mapping is
    /// transID 371 (`getTNewsPath:category:YES`). The server replies with
    /// a single `newsThreadList` (object key 321) carrying every thread's
    /// metadata in one blob.
    func fetchNewsThreads(at path: RemotePath) async throws -> [NewsThread]

    /// Fetch the body of a single thread.
    func fetchNewsThread(
        at path: RemotePath,
        threadID: UInt16,
        type: String
    ) async throws -> NewsThread

    /// Delete a whole bundle / category.
    func deleteNewsBundle(at path: RemotePath) async throws

    /// Delete a single thread (or its full sub-tree when `cascade` is true).
    func deleteNewsThread(
        at path: RemotePath,
        threadID: UInt16,
        cascade: Bool
    ) async throws

    /// Create a new bundle or category at the given path.
    func createNewsBundle(
        at path: RemotePath,
        name: String,
        isCategory: Bool
    ) async throws

    /// Post a new thread (`threadID == 0` for a top-level post; otherwise the
    /// parent thread id).
    func postNewsThread(
        at path: RemotePath,
        parentThreadID: UInt16,
        title: String,
        type: String,
        body: String
    ) async throws

    // MARK: File system

    /// List the contents of a remote folder.
    func listFiles(at path: RemotePath) async throws -> [RemoteFile]

    /// Delete one entry.
    func deleteEntry(at path: RemotePath, name: String) async throws

    /// Create a folder.
    func createFolder(at path: RemotePath, name: String) async throws

    /// Fetch one entry's extended info.
    func fetchFileInfo(at path: RemotePath, name: String) async throws -> RemoteFileInfo

    /// Rename a file or update its comment.
    func updateFileMetadata(
        at path: RemotePath,
        name: String,
        change: FileMetadataChange
    ) async throws

    /// Move a file or folder.
    func moveEntry(
        from sourcePath: RemotePath,
        name: String,
        to destinationPath: RemotePath
    ) async throws

    /// Place an alias (Hotline-style symbolic link) at a destination path.
    func makeAlias(
        from sourcePath: RemotePath,
        name: String,
        to destinationPath: RemotePath
    ) async throws

    // MARK: Transfers

    /// Begin downloading a file. `dataForkOffset` and `resourceForkOffset`
    /// support resuming a partial download (zero for a fresh download).
    func startDownload(
        at path: RemotePath,
        name: String,
        dataForkOffset: UInt32,
        resourceForkOffset: UInt32
    ) async throws -> TransferHandle

    /// Begin downloading a folder as a stream of files.
    func startFolderDownload(at path: RemotePath, name: String) async throws -> TransferHandle

    /// Fetch the server's banner image (transID 212). The 212 reply
    /// carries a `transferID` + `transferSize`; the client opens an
    /// HTXF side-channel with the banner-flavoured preamble (type=2)
    /// and reads the bytes. Returns the raw payload alongside the
    /// declared `BannerType` (1 = URL, 3 = JPEG, 4 = GIF, 5 = BMP,
    /// 6 = PICT) so callers can decode + display it correctly.
    /// `nil` when the server hasn't configured one.
    func downloadBanner() async throws -> ServerBanner?

    /// Begin uploading a file.
    func startUpload(
        at path: RemotePath,
        name: String,
        size: UInt32,
        resume: Bool
    ) async throws -> TransferHandle

    /// Begin uploading a folder.
    func startFolderUpload(
        at path: RemotePath,
        name: String,
        size: UInt32,
        itemCount: UInt16,
        resume: Bool
    ) async throws -> TransferHandle

    /// Cancel an in-flight transfer.
    func cancelTransfer(_ handle: TransferHandle) async throws

    /// Stream bytes for a download started with `startDownload(...)`.
    ///
    /// The stream finishes when the server has delivered every byte, or
    /// throws `HotlineError.cancelled` if `cancelTransfer(_:)` is called
    /// while it's iterating. Each element is one chunk as it arrives —
    /// callers concatenate to disk or wherever they want the bytes.
    func downloadStream(for handle: TransferHandle) -> AsyncThrowingStream<Data, Error>

    /// Download a single file as a fully-parsed `UploadEnvelope`
    /// (data fork + resource fork + metadata). Requires the session to
    /// have negotiated `resourceForkSupport` on login — check
    /// `serverSupportsResourceForks` first. Buffers the whole envelope
    /// in memory; for multi-GB downloads use `downloadStream` and
    /// accept losing the resource fork.
    func downloadEnvelope(for handle: TransferHandle) async throws -> UploadEnvelope

    /// Claim the resource fork buffered during the most recent framed
    /// `downloadStream(for:)`. Read-once: subsequent calls return an
    /// empty `Data`. Always empty for non-framed handles, files with
    /// no resource fork, or sessions that didn't negotiate
    /// `resourceForkSupport`. Lets callers stream the data fork
    /// through `downloadStream` for progress and pick up the resource
    /// fork afterward.
    func consumeResourceFork(for transferID: UInt32) async -> Data

    /// `true` after a `login(...)` against a server that echoed the
    /// `resourceForkSupport` capability (Heidrun extension 0xE002).
    /// When set, `startDownload(...)` returns a `TransferHandle` whose
    /// side channel ships the FILP/INFO/DATA/MACR envelope, suitable
    /// for `downloadEnvelope(for:)`. When unset the side channel is
    /// raw data-fork bytes and only `downloadStream(for:)` works.
    var serverSupportsResourceForks: Bool { get async }

    /// Send the bytes for an upload started with `startUpload(...)`.
    ///
    /// `content` is the data fork. `resourceFork` rides the MACR trailer
    /// — pass empty data for the common data-fork-only case. `type` and
    /// `creator` are the four-character HFS-style codes the server stores
    /// alongside the file. Times default to "now" — the server has its
    /// own concept of when the file was created so this is mostly
    /// informational.
    ///
    /// `progress` is called with the cumulative count of data-fork bytes
    /// (not framing overhead) that have been pushed to the side channel.
    /// Use it to drive a progress bar; pass `nil` if you don't care.
    func sendUpload(
        _ content: Data,
        for handle: TransferHandle,
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        resourceFork: Data,
        progress: (@Sendable (UInt64) async -> Void)?
    ) async throws

    /// Send the per-item items for a folder upload started with
    /// `startFolderUpload(...)`. Directories appear as items with
    /// `isDirectory == true` and empty `data`; files carry their data
    /// fork. `progress` reports cumulative data-fork bytes accepted by
    /// the server, fired once per item.
    func sendFolderUpload(
        _ items: [FolderUploadItem],
        for handle: TransferHandle,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        progress: (@Sendable (UInt64) async -> Void)?
    ) async throws
}

extension HotlineClient {
    /// Convenience overload that defaults the metadata to "now",
    /// generic file/creator codes, and an empty resource fork.
    public func sendUpload(
        _ content: Data,
        for handle: TransferHandle,
        fileName: String,
        progress: (@Sendable (UInt64) async -> Void)? = nil
    ) async throws {
        let now = Date()
        try await sendUpload(
            content,
            for: handle,
            fileName: fileName,
            type: .file,
            creator: .unknown,
            creationDate: now,
            modificationDate: now,
            resourceFork: Data(),
            progress: progress
        )
    }

    /// Convenience overload that keeps the explicit metadata but defaults
    /// the resource fork to empty so existing data-fork-only callers can
    /// stay on the old signature.
    public func sendUpload(
        _ content: Data,
        for handle: TransferHandle,
        fileName: String,
        type: FourCharCode,
        creator: FourCharCode,
        creationDate: Date,
        modificationDate: Date,
        progress: (@Sendable (UInt64) async -> Void)?
    ) async throws {
        try await sendUpload(
            content,
            for: handle,
            fileName: fileName,
            type: type,
            creator: creator,
            creationDate: creationDate,
            modificationDate: modificationDate,
            resourceFork: Data(),
            progress: progress
        )
    }

    /// Convenience overload for `sendFolderUpload(...)` that defaults
    /// metadata to "now" and generic file/creator codes.
    public func sendFolderUpload(
        _ items: [FolderUploadItem],
        for handle: TransferHandle,
        progress: (@Sendable (UInt64) async -> Void)? = nil
    ) async throws {
        let now = Date()
        try await sendFolderUpload(
            items,
            for: handle,
            type: .file,
            creator: .unknown,
            creationDate: now,
            modificationDate: now,
            progress: progress
        )
    }
}
