import Foundation
import Testing
@testable import HeidrunCore

@Suite("RemotePath")
struct RemotePathTests {
    @Test("empty path is the root")
    func emptyIsRoot() {
        let root = RemotePath()
        #expect(root.isRoot)
        #expect(root.components.isEmpty)
        #expect(root.displayPath == "/")
    }

    @Test("array literal initialiser populates components in order")
    func arrayLiteral() {
        let path: RemotePath = ["Drop Box", "Incoming"]
        #expect(path.components == ["Drop Box", "Incoming"])
        #expect(!path.isRoot)
        #expect(path.displayPath == "/Drop Box/Incoming")
    }

    @Test("appending grows by one component without mutating the original")
    func appending() {
        let root = RemotePath()
        let one = root.appending("Public")
        let two = one.appending("Files")

        #expect(root.isRoot)
        #expect(one.components == ["Public"])
        #expect(two.components == ["Public", "Files"])
    }

    @Test("parent walks up; root's parent is the root")
    func parent() {
        let path: RemotePath = ["a", "b", "c"]
        #expect(path.parent.components == ["a", "b"])
        #expect(path.parent.parent.components == ["a"])
        #expect(path.parent.parent.parent.isRoot)
        #expect(path.parent.parent.parent.parent.isRoot)
    }
}
