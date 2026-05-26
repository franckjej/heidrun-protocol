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

    /// The server's TLS certificate was not trusted: the user declined a
    /// self-signed cert, or a pinned certificate changed and re-trust was
    /// cancelled.
    case certificateNotTrusted
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
        case .certificateNotTrusted:
            return "certificate not trusted"
        }
    }

    /// User-facing rendering suitable for an alert / banner.
    ///
    /// `description` exposes the raw protocol shape (used in logs and
    /// tests). `userMessage` paraphrases it into a sentence the operator
    /// can act on — lifting the server's `.errorMessage` payload when
    /// present and turning transport-level cases into something readable.
    public var userMessage: String {
        switch self {
        case .notConnected:
            return "Connection lost. The server stopped responding."
        case .notLoggedIn:
            return "Not logged in."
        case let .serverError(_, message):
            guard let message, !message.isEmpty else {
                return "The server rejected the request."
            }
            // Capitalise the first character so it reads as a sentence
            // even when the server sent a lowercase phrase.
            return message.prefix(1).uppercased() + message.dropFirst()
        case .malformedReply(let reason):
            return "The server's reply didn't make sense (\(reason))."
        case .cancelled:
            return "Operation cancelled."
        case .timedOut:
            return "The server didn't respond in time."
        case .permissionDenied:
            return "Your account doesn't have permission to do that."
        case .notImplemented:
            return "Heidrun doesn't support this yet."
        case .certificateNotTrusted:
            return "The server's security certificate wasn't trusted, so the connection was cancelled."
        }
    }
}
