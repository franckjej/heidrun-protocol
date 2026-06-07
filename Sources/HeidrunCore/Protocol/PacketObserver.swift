import Foundation

/// Hook that fires once per outbound transaction (after encoding,
/// before the bytes leave the wire) and once per inbound transaction
/// (after parsing, before reply correlation or event broadcast).
///
/// Designed for a developer console / packet inspector: the consumer
/// sees the same view of the wire as both ends of the conversation
/// without having to instrument the protocol layer itself. The same
/// observer shape works for the Darwin `HotlineNetworkClient` and the
/// cross-platform `NIOHotlineClient`.
///
/// Treat the handler as best-effort logging: it must never throw, and
/// it should return quickly because it runs on the client's actor
/// context. Anything heavier (formatting, persistence, UI updates)
/// should hop to a different actor / queue.
public struct PacketObserver: Sendable {
    public enum Direction: Sendable, Equatable {
        /// Sent by us — encoded `[PacketField]`s about to go on the wire.
        case outbound
        /// Pushed by the server — decoded from the wire.
        case inbound
    }

    /// `(direction, header, fields)` — `header` carries class /
    /// transactionID / taskNumber / errorID; `fields` is the decoded
    /// payload. For dialect-spotting, check `PacketObserver.isKnown(_:)`
    /// on `header.transactionID` to flag unknown inbound transactions.
    public let handle: @Sendable (Direction, PacketHeader, [PacketField]) -> Void

    public init(handle: @escaping @Sendable (Direction, PacketHeader, [PacketField]) -> Void) {
        self.handle = handle
    }

    /// True when this client knows the transaction id — either as a
    /// server-pushed info transaction (`InfoTransaction`) or as one
    /// of the request IDs the client itself sends (and therefore
    /// expects a reply on the same id). Anything else is "unknown"
    /// territory worth flagging in a developer console; dialect-
    /// custom server extensions show up here.
    ///
    /// `TransactionType` enum is deliberately NOT consulted — its
    /// values are HEClient.m task-type IDs (1, 2, 3, …), not wire
    /// transaction IDs.
    public static func isKnown(_ transactionID: UInt16) -> Bool {
        if InfoTransaction(rawValue: transactionID) != nil { return true }
        return knownRequestIDs.contains(transactionID)
    }

    /// Wire transaction IDs the Heidrun clients send to the server.
    /// Replies carry the same id, so this doubles as the
    /// "recognised reply" set. Curated from the literal IDs in
    /// `HotlineNetworkClient` and `NIOHotlineClient`; update if a
    /// new transaction is added in either client.
    static let knownRequestIDs: Set<UInt16> = [
        101,            // getNewsFile
        103,            // postNewNews
        105,            // sendChat
        107,            // login
        108,            // sendPrivateMessage
        110,            // kick
        112,            // createPrivateChat (CHAT_CREATE)
        113,            // invite (CHAT_INVITE)
        114,            // rejectPrivateChat (CHAT_DECLINE)
        115,            // joinPrivateChat (CHAT_JOIN)
        116,            // leavePrivateChat (CHAT_PART)
        120,            // changeChatSubject (CHAT_SUBJECT)
        121,            // agreeToAgreement
        200,            // listFiles
        202,            // downloadFile
        203,            // uploadFile
        204,            // deleteEntry
        205,            // createFolder
        206,            // getFileInfo
        207,            // setFileInfo
        208,            // moveFile
        209,            // makeAlias
        210,            // downloadFolder
        212,            // downloadBanner
        213,            // uploadFolder
        300,            // getUserList
        303,            // getUserInfo
        304,            // changeNickname
        305,            // postClientInfo
        350,            // newUser
        351,            // deleteUser
        352,            // openLogin
        353,            // modifyLogin
        354,            // makeUser (reserved)
        355,            // broadcast
        370,            // getNewsCategoryNameList
        371,            // getNewsArticleList
        380,            // deleteNewsItem
        381,            // newNewsCategory
        382,            // newNewsItem
        400,            // getNewsArticleData
        410,            // postNewsArticle
        411,            // deleteNewsArticle
        500             // sendPing (Heidrun extension)
    ]
}
