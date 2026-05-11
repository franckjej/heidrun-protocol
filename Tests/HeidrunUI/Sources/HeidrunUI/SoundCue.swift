import Foundation

/// Named cues for the bundled `.aiff` clips inherited from the 2002 Heidrun
/// release. Each case maps 1:1 to a file in `Resources/Sounds`; the file
/// extension is implied (`.aiff`).
public enum SoundCue: String, CaseIterable, Sendable {
    case login    = "login"
    case logout   = "logout"
    case chatPost = "chatpost"
    case doorbell = "doorbell"
    case news     = "news"
    case serverMessage = "svrmsg"
    case fileDone = "filedone"

    /// Bundle resource name without extension.
    public var resourceName: String { rawValue }
}
