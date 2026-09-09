/// A folder's role, derived from its name the way Hotline 1.8 and the
/// 2002 Heidrun client did: "upload" wins, then "drop box", else normal.
/// Case-insensitive substring match; pure stdlib so it builds on Linux.
public enum FolderRole: Sendable, Hashable {
    case normal
    case upload
    case dropBox

    public init(name: String) {
        let lowered = name.lowercased()
        if lowered.contains("upload") {
            self = .upload
        } else if lowered.contains("drop box") {
            self = .dropBox
        } else {
            self = .normal
        }
    }
}

extension RemotePath {
    /// Some component is a drop box, so this path is at or below its
    /// contents. Users without `viewDropBoxes` may not read here.
    public var containsDropBox: Bool {
        components.contains { FolderRole(name: $0) == .dropBox }
    }

    /// Some component is an upload folder or a drop box — the only places
    /// a user without `uploadAnywhere` may upload to.
    public var isUploadTarget: Bool {
        components.contains { FolderRole(name: $0) != .normal }
    }
}
