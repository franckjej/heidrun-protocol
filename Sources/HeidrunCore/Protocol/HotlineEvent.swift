import Foundation

/// A server-pushed message the client can deliver to subscribers.
///
/// In the original Heidrun, server pushes were dispatched by `HEClient`
/// via direct method calls into modules — `heiModuleReceivedData:` for
/// each `kInfo*` transaction. Here they're collected into a typed enum so
/// callers can subscribe with a single `for await event in client.events`
/// loop.
public enum HotlineEvent: Sendable, Hashable {
    /// A new piece of plain news was posted to the legacy news bulletin.
    case newsPosted(text: String)

    /// A private message arrived.
    case messageReceived(from: UInt16, message: String)

    /// A chat line arrived (relay chat, optionally an action/`/me` style line).
    case chatReceived(chat: ChatID?, message: String, isAction: Bool)

    /// The server is presenting its agreement / login banner.
    case agreementReceived(text: String, autoAgree: Bool)

    /// The connection was disconnected by the server.
    case disconnected(reason: String?)

    /// Another user invited us into a private chat room.
    case privateChatInvited(chat: ChatID, fromUser: UInt16, message: String?)

    /// Someone joined a private chat we're in.
    case privateChatJoined(chat: ChatID, user: User)

    /// Someone left a private chat we're in.
    case privateChatLeft(chat: ChatID, socket: UInt16)

    /// A private chat's subject changed.
    case privateChatSubjectChanged(chat: ChatID, subject: String)

    /// The transfer queue was updated (something joined, finished, or made
    /// progress).
    case transferQueueUpdated

    /// A specific user's record changed (icon, status, nickname).
    case userChanged(user: User)

    /// A user disconnected from the server.
    case userLeft(socket: UInt16)

    /// The server sent the full user list.
    case userListReceived(users: [User])

    /// The server (or another admin) broadcast a notice to everyone.
    case broadcastReceived(message: String)
}
