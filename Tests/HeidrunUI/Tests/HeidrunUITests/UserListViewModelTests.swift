import Foundation
import Testing
@testable import HeidrunUI
import HeidrunCore

@MainActor
@Suite("UserListViewModel")
struct UserListViewModelTests {
    @Test("users start empty")
    func usersStartEmpty() {
        let client = FakeUserListClient()
        let vm = UserListViewModel(client: client)
        #expect(vm.users.isEmpty)
    }

    @Test("loadError starts nil")
    func loadErrorStartsNil() {
        let client = FakeUserListClient()
        let vm = UserListViewModel(client: client)
        #expect(vm.loadError == nil)
    }

    @Test("start() seeds roster from fetchUserList")
    func startSeedsRosterFromFetch() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([
            User(socket: 1, nickname: "alice"),
            User(socket: 2, nickname: "bob")
        ])
        let vm = UserListViewModel(client: client)
        await vm.start()
        #expect(vm.users.map(\.nickname) == ["alice", "bob"])
        #expect(vm.loadError == nil)
    }

    @Test("start() failure stores loadError; users stay empty")
    func startFailureStoresLoadError() async {
        struct Boom: Error {}
        let client = FakeUserListClient()
        client.fetchUserListResponse = .failure(Boom())
        let vm = UserListViewModel(client: client)
        await vm.start()
        #expect(vm.users.isEmpty)
        #expect(vm.loadError != nil)
    }

    @Test("userListReceived replaces the roster")
    func eventUserListReceivedReplacesRoster() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([User(socket: 1, nickname: "alice")])
        let vm = UserListViewModel(client: client)
        await vm.start()

        client.emit(.userListReceived(users: [
            User(socket: 2, nickname: "bob"),
            User(socket: 3, nickname: "carol")
        ]))
        await vm.waitForRosterChange { $0.map(\.nickname) == ["bob", "carol"] }
        #expect(vm.users.map(\.nickname) == ["bob", "carol"])
    }

    @Test("userChanged updates an existing socket in place")
    func eventUserChangedUpdatesExisting() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([
            User(socket: 1, nickname: "alice"),
            User(socket: 2, nickname: "bob")
        ])
        let vm = UserListViewModel(client: client)
        await vm.start()

        client.emit(.userChanged(user: User(socket: 1, nickname: "ALICE")))
        await vm.waitForRosterChange { $0.first?.nickname == "ALICE" }
        #expect(vm.users.map(\.nickname) == ["ALICE", "bob"])
    }

    @Test("userChanged appends a previously-unseen socket")
    func eventUserChangedAppendsNew() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([User(socket: 1, nickname: "alice")])
        let vm = UserListViewModel(client: client)
        await vm.start()

        client.emit(.userChanged(user: User(socket: 7, nickname: "dave")))
        await vm.waitForRosterChange { $0.count == 2 }
        #expect(vm.users.map(\.socket) == [1, 7])
        #expect(vm.users.last?.nickname == "dave")
    }

    @Test("userLeft removes the matching socket")
    func eventUserLeftRemoves() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([
            User(socket: 1, nickname: "alice"),
            User(socket: 2, nickname: "bob")
        ])
        let vm = UserListViewModel(client: client)
        await vm.start()

        client.emit(.userLeft(socket: 1))
        await vm.waitForRosterChange { $0.map(\.socket) == [2] }
        #expect(vm.users.map(\.nickname) == ["bob"])
    }

    @Test("userLeft for an unknown socket is a no-op")
    func eventUserLeftUnknownIsNoOp() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([User(socket: 1, nickname: "alice")])
        let vm = UserListViewModel(client: client)
        await vm.start()

        client.emit(.userLeft(socket: 99))
        // Give the event loop a tick to process; roster should be unchanged.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(vm.users.map(\.socket) == [1])
    }

    @Test("userListReceived clears a prior loadError")
    func eventUserListReceivedClearsLoadError() async {
        struct Boom: Error {}
        let client = FakeUserListClient()
        client.fetchUserListResponse = .failure(Boom())
        let vm = UserListViewModel(client: client)
        await vm.start()
        #expect(vm.loadError != nil)

        client.emit(.userListReceived(users: [User(socket: 1, nickname: "alice")]))
        await vm.waitForRosterChange { $0.map(\.nickname) == ["alice"] }
        #expect(vm.loadError == nil)
    }

    @Test("cancel() stops applying subsequent events")
    func cancelStopsApplyingEvents() async {
        let client = FakeUserListClient()
        client.fetchUserListResponse = .success([User(socket: 1, nickname: "alice")])
        let vm = UserListViewModel(client: client)
        await vm.start()
        vm.cancel()

        // Give the cancelled task a tick to exit.
        try? await Task.sleep(for: .milliseconds(20))

        client.emit(.userLeft(socket: 1))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(vm.users.map(\.nickname) == ["alice"], "event should be ignored after cancel")
    }

    @Test("sendIM forwards to client.sendPrivateMessage")
    func sendIMForwardsToClient() async throws {
        let client = FakeUserListClient()
        let vm = UserListViewModel(client: client)
        try await vm.sendIM(to: 42, body: "hello")
        #expect(client.sentMessages.count == 1)
        #expect(client.sentMessages.first?.socket == 42)
        #expect(client.sentMessages.first?.message == "hello")
    }

    @Test("requestInfo returns the UserInfo from client.fetchUserInfo")
    func requestInfoReturnsFromClient() async throws {
        let client = FakeUserListClient()
        let expected = UserInfo(
            user: User(socket: 7, nickname: "dave"),
            infoText: "hello world"
        )
        client.fetchUserInfoResponse = .success(expected)
        let vm = UserListViewModel(client: client)
        let result = try await vm.requestInfo(for: 7)
        #expect(result == expected)
    }
}

private extension UserListViewModel {
    /// Spin until `predicate(users)` becomes true, bounded so a stuck test
    /// fails fast instead of hanging.
    func waitForRosterChange(
        timeout: Duration = .seconds(1),
        _ predicate: ([User]) -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !predicate(users), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Test helpers

private final class FakeUserListClient: HotlineClient, @unchecked Sendable {
    let events: AsyncStream<HotlineEvent>
    private let continuation: AsyncStream<HotlineEvent>.Continuation
    var fetchUserListResponse: Result<[User], Error> = .success([])
    var fetchUserInfoResponse: Result<UserInfo, Error> = .success(
        UserInfo(user: User(socket: 0), infoText: "")
    )
    var sentMessages: [(socket: UInt16, message: String)] = []

    init() {
        var cont: AsyncStream<HotlineEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func emit(_ event: HotlineEvent) { continuation.yield(event) }
    func finishEvents() { continuation.finish() }

    var connectionInfo: HotlineConnectionInfo {
        get async {
            HotlineConnectionInfo(
                clientVersion: 0,
                protocolVersion: 0,
                connectionSocket: 0,
                lastTaskNumber: 0,
                settings: ConnectionSettings(name: "", address: "")
            )
        }
    }
    func disconnect() async {}
    func requestAttention(_ flags: AttentionFlags) async {}
    func sendPing() async throws {}
    func login(name: String, password: String, nickname: String, icon: UInt16) async throws {}
    func agreeToAgreement(nickname: String, icon: UInt16) async throws {}
    func changeNickname(_ nickname: String, icon: UInt16, persist: Bool) async throws {}
    func fetchUserList() async throws -> [User] { try fetchUserListResponse.get() }
    func fetchUserInfo(socket: UInt16) async throws -> UserInfo { try fetchUserInfoResponse.get() }
    func kick(socket: UInt16, ban: Bool) async throws {}
    func fetchNewsFeed() async throws -> String { "" }
    func postPlainNews(_ text: String) async throws {}
    func broadcast(_ message: String) async throws {}
    func sendPrivateMessage(_ message: String, to socket: UInt16) async throws {
        sentMessages.append((socket: socket, message: message))
    }
    func sendChat(_ message: String, in chat: ChatID?, isAction: Bool) async throws {}
    func createPrivateChat(with socket: UInt16) async throws -> ChatID { ChatID(rawValue: 0) }
    func joinPrivateChat(_ chat: ChatID) async throws {}
    func rejectPrivateChat(_ chat: ChatID) async throws {}
    func leavePrivateChat(_ chat: ChatID) async throws {}
    func changeChatSubject(_ subject: String, in chat: ChatID) async throws {}
    func invite(socket: UInt16, to chat: ChatID) async throws {}
    func createLogin(name: String, password: String, nickname: String, privileges: UserPrivileges) async throws {}
    func deleteLogin(_ name: String) async throws {}
    func openLogin(_ name: String) async throws -> (nickname: String, privileges: UserPrivileges) {
        (nickname: "", privileges: [])
    }
    func modifyLogin(name: String, password: String?, nickname: String, privileges: UserPrivileges) async throws {}
    func fetchNewsBundles(at path: RemotePath, isCategory: Bool) async throws -> [NewsBundle] { [] }
    func fetchNewsThread(at path: RemotePath, threadID: UInt16, type: String) async throws -> NewsThread {
        NewsThread(threadID: threadID)
    }
    func deleteNewsBundle(at path: RemotePath) async throws {}
    func deleteNewsThread(at path: RemotePath, threadID: UInt16, cascade: Bool) async throws {}
    func createNewsBundle(at path: RemotePath, name: String, isCategory: Bool) async throws {}
    func postNewsThread(at path: RemotePath, parentThreadID: UInt16, title: String, type: String, body: String) async throws {}
    func listFiles(at path: RemotePath) async throws -> [RemoteFile] { [] }
    func deleteEntry(at path: RemotePath, name: String) async throws {}
    func createFolder(at path: RemotePath, name: String) async throws {}
    func fetchFileInfo(at path: RemotePath, name: String) async throws -> RemoteFileInfo {
        RemoteFileInfo(file: RemoteFile(name: name))
    }
    func updateFileMetadata(at path: RemotePath, name: String, change: FileMetadataChange) async throws {}
    func moveEntry(from sourcePath: RemotePath, name: String, to destinationPath: RemotePath) async throws {}
    func makeAlias(from sourcePath: RemotePath, name: String, to destinationPath: RemotePath) async throws {}
    func startDownload(at path: RemotePath, name: String, dataForkOffset: UInt32, resourceForkOffset: UInt32) async throws -> TransferHandle {
        TransferHandle(transferID: 0, totalSize: 0)
    }
    func startFolderDownload(at path: RemotePath, name: String) async throws -> TransferHandle {
        TransferHandle(transferID: 0, totalSize: 0)
    }
    func startUpload(at path: RemotePath, name: String, size: UInt32, resume: Bool) async throws -> TransferHandle {
        TransferHandle(transferID: 0, totalSize: 0)
    }
    func startFolderUpload(at path: RemotePath, name: String, size: UInt32, itemCount: UInt16, resume: Bool) async throws -> TransferHandle {
        TransferHandle(transferID: 0, totalSize: 0)
    }
    func cancelTransfer(_ handle: TransferHandle) async throws {}
    func downloadStream(for handle: TransferHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendUpload(_ content: Data, for handle: TransferHandle, fileName: String, type: HeidrunCore.FourCharCode, creator: HeidrunCore.FourCharCode, creationDate: Date, modificationDate: Date, progress: (@Sendable (UInt64) async -> Void)?) async throws {}
}
