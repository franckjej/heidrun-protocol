import Foundation
import HeidrunCore

/// Seed news data used by the test server.
///
/// Two parallel worlds:
///   * `plainFeed` — a single appended-to text blob, served by transID 101.
///   * Threaded tree — a root containing two folders (bundles, kind=2),
///     each with one category (kind=3) holding a couple of threads.
enum NewsFixtures {
    static let initialPlainFeed: String = """
    Welcome to the Heidrun test server.

    This is a seeded post so the feed isn't empty on first load.

    Type into the composer below and hit Cmd+Return — your post is\
    \u{0020}echoed back through the kInfoNewPost event.
    """

    /// Top-level layout. A "bundle" (kind=2) is a folder you navigate
    /// into; a "category" (kind=3) is a leaf that contains posts.
    static let bundleTree: [BundleNode] = [
        BundleNode(name: "General", kind: .bundle, children: [
            BundleNode(name: "Announcements", kind: .category, threads: [
                Post(
                    title: "Server is up",
                    author: "admin",
                    body: "If you can read this, login and news fetching both worked. Welcome."
                ),
                Post(
                    title: "Two-week roadmap",
                    author: "admin",
                    body: "Next we'll wire the user list, then folder transfers."
                )
            ]),
            BundleNode(name: "Random", kind: .category, threads: [
                Post(
                    title: "Nostalgia",
                    author: "alice",
                    body: "Anyone else remember running Hotline 1.2.3 over dial-up?"
                )
            ])
        ]),
        BundleNode(name: "Support", kind: .bundle, children: [
            BundleNode(name: "Bugs", kind: .category, threads: [
                Post(
                    title: "Folder shows 1 item but empty inside",
                    author: "tester",
                    body: "Reproduces every time on the threaded news pane. Look for missing object-key 321 decoder."
                )
            ])
        ])
    ]
}

/// One node in the threaded-news tree. A node is either a bundle (a
/// folder containing more nodes) or a category (a leaf with threads).
struct BundleNode: Sendable {
    let name: String
    let kind: NewsBundle.Kind
    var children: [BundleNode] = []
    var threads: [Post] = []
}

struct Post: Sendable {
    let title: String
    let author: String
    let body: String
}

extension Array where Element == BundleNode {
    /// Descend into this tree following `components`. Returns the children
    /// (other nodes) at that level, or `nil` if the path doesn't exist or
    /// terminates in a category (use `threads(at:)` for that case).
    func children(at components: [String]) -> [BundleNode]? {
        var current = self
        for component in components {
            guard let next = current.first(where: { $0.name == component }) else {
                return nil
            }
            current = next.children
        }
        return current
    }

    /// Walk to a category node and return its threads. Returns `nil` if
    /// the path doesn't end at a category.
    func threads(at components: [String]) -> [Post]? {
        guard !components.isEmpty else { return nil }
        var pool = self
        for component in components.dropLast() {
            guard let next = pool.first(where: { $0.name == component }) else {
                return nil
            }
            pool = next.children
        }
        guard let leaf = pool.first(where: { $0.name == components.last }),
              leaf.kind == .category else {
            return nil
        }
        return leaf.threads
    }
}
