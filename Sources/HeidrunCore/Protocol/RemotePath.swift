/// A path inside the server's namespace, used both for the file system and
/// for threaded news.
///
/// In the original protocol a path is an `NSArray` of folder names ordered
/// root-to-leaf. `RemotePath` keeps that ordering and stays trivially
/// convertible from string literals so call sites read naturally:
///
/// ```swift
/// try await client.listFiles(at: ["Drop Box", "Incoming"])
/// ```
public struct RemotePath: Sendable, Hashable, ExpressibleByArrayLiteral {
    public var components: [String]

    public init(components: [String] = []) {
        self.components = components
    }

    public init(arrayLiteral elements: String...) {
        self.components = elements
    }

    /// `true` when this is the server's top-level directory.
    public var isRoot: Bool { components.isEmpty }

    /// Drop the deepest component. Returns the same path when already at root.
    public var parent: RemotePath {
        guard !components.isEmpty else { return self }
        return RemotePath(components: components.dropLast())
    }

    /// Append a component, producing a child path.
    public func appending(_ component: String) -> RemotePath {
        RemotePath(components: components + [component])
    }

    /// Forward-slash separated for display.
    public var displayPath: String {
        "/" + components.joined(separator: "/")
    }
}
