import Foundation

/// Reasons a `HotlineClient` operation can fail.
///
/// The original protocol surfaced errors as a non-zero `errorID` field on the
/// reply header (sometimes paired with a "Error Message" object inside the
/// payload). `HotlineError` keeps both pieces of information and adds a few
/// transport-level cases the original code mixed with reply parsing.
public enum HotlineError: Error, Sendable, Hashable {
    /// The TCP connection isn't open or has dropped.
    case notConnected

    /// The connection is up but the user hasn't completed the login handshake.
    case notLoggedIn

    /// The server replied with a non-zero error id.
    case serverError(id: UInt32, message: String?)

    /// The server replied but the payload didn't conform to the expected
    /// shape (missing required object IDs, length mismatch, etc.).
    case malformedReply(reason: String)

    /// The transaction was cancelled before the server replied.
    case cancelled

    /// The server didn't reply within the configured timeout.
    case timedOut

    /// The connecting party tried an operation their `UserPrivileges` mask
    /// doesn't permit.
    case permissionDenied

    /// The current `HotlineClient` implementation doesn't yet handle this
    /// transaction. Callers can fall back to the legacy implementation
    /// or skip the operation; the wire transports it identically.
    case notImplemented
}

extension HotlineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notConnected:
            return "not connected"
        case .notLoggedIn:
            return "not logged in"
        case let .serverError(id, message):
            if let message {
                return "server error \(id): \(message)"
            }
            return "server error \(id)"
        case .malformedReply(let reason):
            return "malformed reply: \(reason)"
        case .cancelled:
            return "cancelled"
        case .timedOut:
            return "timed out"
        case .permissionDenied:
            return "permission denied"
        case .notImplemented:
            return "not implemented"
        }
    }
}
