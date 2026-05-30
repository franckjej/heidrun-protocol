/// Structured "what went wrong" code that a Heidrun server can attach
/// to an error reply via the `.errorKind` field (object key `0xE001`).
///
/// **This is a Heidrun extension, not standard Hotline.** Classic
/// servers (and Heidrun servers before v1.0.0-rc10) only set
/// `header.errorID = 1` and pack the human-readable text into
/// `.errorMessage`. When `.errorKind` is absent, the client falls back
/// to `HotlineError.serverError(id:message:)` and surfaces the message
/// verbatim.
///
/// Values are stable on the wire. Add new cases by appending — never
/// reassign existing ones, and never reuse numbers from deleted cases.
public enum HotlineErrorKind: UInt16, Sendable, Hashable, CaseIterable {
    /// An upload (TX 203) was rejected because a file with the same
    /// name already exists at the destination path and the client did
    /// not set the resume parameter. The client should typically offer
    /// the user **Replace** (delete via TX 204, then re-upload),
    /// **Resume** (re-issue with resume=1, which appends to the
    /// existing file), or **Cancel**.
    case fileAlreadyExists = 1
}
