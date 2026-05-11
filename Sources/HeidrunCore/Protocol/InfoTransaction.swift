/// Server-pushed transaction codes carried in `PacketHeader.transactionID`.
///
/// Where `TransactionType` describes what the client is asking the server
/// to do, `InfoTransaction` enumerates the unsolicited messages the server
/// pushes at us and the well-known transaction IDs of replies. The values
/// match the `kInfo*` constants from `HeiSendingProtocol.h`.
public enum InfoTransaction: UInt16, Sendable, CaseIterable {
    case newPost                 = 102
    case message                 = 104
    case relayChat               = 106
    case agreement               = 109
    case disconnected            = 111
    case privateChatInvitation   = 113
    case privateChatJoined       = 117
    case privateChatLeft         = 118
    case privateChatChangedSubject = 119
    case transferQueueUpdate     = 211
    case userChanged             = 301
    case userLeft                = 302
    case userList                = 354
    case broadcast               = 355
}
