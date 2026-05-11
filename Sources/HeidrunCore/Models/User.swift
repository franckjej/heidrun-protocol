/// A user that appears in the server's user list.
///
/// Replaces `HeiUser` from the original framework. The Objective-C class
/// wrapped its mutable state in an `NSLock`; here the type is a plain value,
/// so callers wanting shared, mutable state hold it inside an actor or any
/// other concurrency primitive of their choice.
public struct User: Sendable, Hashable, Identifiable {
    /// Server-assigned socket number. Acts as the user's identity within the
    /// connection and is used as `Identifiable.id`.
    public var socket: UInt16

    /// Index into the server's icon set.
    public var icon: UInt16

    /// Encoded `UserStatus` (high byte colour, low byte flag mask).
    public var status: UserStatus

    /// Permission mask for what this user is allowed to do.
    public var privileges: UserPrivileges

    /// Display name.
    public var nickname: String

    public init(
        socket: UInt16,
        icon: UInt16 = 0,
        status: UserStatus = .init(),
        privileges: UserPrivileges = [],
        nickname: String = ""
    ) {
        self.socket = socket
        self.icon = icon
        self.status = status
        self.privileges = privileges
        self.nickname = nickname
    }

    public var id: UInt16 { socket }
}
