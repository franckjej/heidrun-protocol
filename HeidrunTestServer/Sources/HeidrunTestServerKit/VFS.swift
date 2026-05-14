import Foundation
import HeidrunCore

/// In-memory file metadata for the test server.
public struct VFSFile: Sendable {
    public var data = Data()
    public var type: HeidrunCore.FourCharCode = .file
    public var creator: HeidrunCore.FourCharCode = .unknown
    public var created = Date()
    public var modified = Date()
    public var comment: String = ""

    public init(
        data: Data = Data(),
        type: HeidrunCore.FourCharCode = .file,
        creator: HeidrunCore.FourCharCode = .unknown,
        created: Date = Date(),
        modified: Date = Date(),
        comment: String = ""
    ) {
        self.data = data
        self.type = type
        self.creator = creator
        self.created = created
        self.modified = modified
        self.comment = comment
    }
}

/// Test server's virtual file system, isolated by `ServerState`.
///
/// Designed to support the file-related transactions the production
/// `HotlineNetworkClient` exercises: listing, navigation, create/delete,
/// rename, get info, and the HTXF side-channel for downloads + uploads.
/// Folder uploads/downloads aren't modelled here — they have their own
/// per-item handshake that lives in the production code under
/// `FolderUploadFraming`/`FolderDownloadDecoder` and isn't needed for the
/// integration tests we want today.
public final class VFS: @unchecked Sendable {
    public final class Folder {
        public var children: [String: Entry] = [:]
        public init() {}
    }

    public enum Entry {
        case file(VFSFile)
        case folder(Folder)
    }

    public let root = Folder()

    public init() {}

    /// Resolve a folder at `path`, returning `nil` if any component is
    /// missing or names a file rather than a folder.
    public func folder(at path: [String]) -> Folder? {
        var current = root
        for component in path {
            guard let entry = current.children[component] else { return nil }
            guard case .folder(let next) = entry else { return nil }
            current = next
        }
        return current
    }

    /// Listing of `path` as `RemoteFile` descriptors.
    public func list(at path: [String]) -> [RemoteFile]? {
        guard let folder = folder(at: path) else { return nil }
        return folder.children
            .sorted { lhs, rhs in
                let lhsIsFolder = isFolder(lhs.value)
                let rhsIsFolder = isFolder(rhs.value)
                if lhsIsFolder != rhsIsFolder { return lhsIsFolder }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { name, entry in
                switch entry {
                case .file(let f):
                    return RemoteFile(
                        name: name,
                        type: f.type,
                        creator: f.creator,
                        size: UInt32(clamping: f.data.count)
                    )
                case .folder(let sub):
                    return RemoteFile(
                        name: name,
                        type: .folder,
                        creator: .unknown,
                        size: 0,
                        itemCount: UInt32(clamping: sub.children.count)
                    )
                }
            }
    }

    /// Extended info for one entry.
    public func info(at path: [String], name: String) -> (RemoteFile, VFSFile)? {
        guard let folder = folder(at: path),
              let entry = folder.children[name] else { return nil }
        switch entry {
        case .file(let f):
            return (
                RemoteFile(
                    name: name,
                    type: f.type,
                    creator: f.creator,
                    size: UInt32(clamping: f.data.count)
                ),
                f
            )
        case .folder(let sub):
            return (
                RemoteFile(
                    name: name,
                    type: .folder,
                    creator: .unknown,
                    size: 0,
                    itemCount: UInt32(clamping: sub.children.count)
                ),
                VFSFile()
            )
        }
    }

    @discardableResult
    public func createFolder(at path: [String], name: String) -> Bool {
        guard let parent = folder(at: path), parent.children[name] == nil else { return false }
        parent.children[name] = .folder(Folder())
        return true
    }

    @discardableResult
    public func delete(at path: [String], name: String) -> Bool {
        guard let parent = folder(at: path), parent.children[name] != nil else { return false }
        parent.children[name] = nil
        return true
    }

    @discardableResult
    public func rename(at path: [String], from: String, to newName: String) -> Bool {
        guard let parent = folder(at: path),
              let entry = parent.children[from],
              parent.children[newName] == nil else { return false }
        parent.children[from] = nil
        parent.children[newName] = entry
        return true
    }

    @discardableResult
    public func setComment(at path: [String], name: String, comment: String) -> Bool {
        guard let parent = folder(at: path) else { return false }
        guard case .file(var f) = parent.children[name] else { return false }
        f.comment = comment
        parent.children[name] = .file(f)
        return true
    }

    /// Bytes for a file at `path/name`, or `nil` if it doesn't exist /
    /// names a folder.
    public func bytes(at path: [String], name: String) -> Data? {
        guard let parent = folder(at: path) else { return nil }
        guard case .file(let f) = parent.children[name] else { return nil }
        return f.data
    }

    /// Insert (or replace) a file with the given data and metadata.
    @discardableResult
    public func putFile(
        at path: [String],
        name: String,
        data: Data,
        type: HeidrunCore.FourCharCode = .file,
        creator: HeidrunCore.FourCharCode = .unknown,
        created: Date = Date(),
        modified: Date = Date()
    ) -> Bool {
        guard let parent = folder(at: path) else { return false }
        let f = VFSFile(
            data: data,
            type: type,
            creator: creator,
            created: created,
            modified: modified
        )
        parent.children[name] = .file(f)
        return true
    }

    /// Append bytes to an existing file (used to commit resumed uploads).
    @discardableResult
    public func appendBytes(at path: [String], name: String, data: Data) -> Bool {
        guard let parent = folder(at: path) else { return false }
        guard case .file(var f) = parent.children[name] else { return false }
        f.data.append(data)
        f.modified = Date()
        parent.children[name] = .file(f)
        return true
    }

    private func isFolder(_ entry: Entry) -> Bool {
        if case .folder = entry { return true }
        return false
    }
}

/// Side-channel transfer the control channel has authorised but the HTXF
/// listener hasn't seen yet. `transferID` is the key callers look up.
public enum PendingTransfer: Sendable {
    case download(path: [String], name: String, dataForkOffset: UInt32)
    case upload(path: [String], name: String, size: UInt32, resume: Bool)
}
