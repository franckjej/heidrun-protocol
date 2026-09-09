import Testing
@testable import HeidrunCore

@Suite("FolderRole")
struct FolderRoleTests {
    @Test("plain names are normal folders")
    func normal() {
        #expect(FolderRole(name: "Software") == .normal)
        #expect(FolderRole(name: "Dropbox") == .normal)   // no space → not a drop box
        #expect(FolderRole(name: "") == .normal)
    }

    @Test("'upload' anywhere in the name, any case, is an upload folder")
    func upload() {
        #expect(FolderRole(name: "Uploads") == .upload)
        #expect(FolderRole(name: "my UPLOAD area") == .upload)
    }

    @Test("'drop box' anywhere in the name, any case, is a drop box")
    func dropBox() {
        #expect(FolderRole(name: "Drop Box") == .dropBox)
        #expect(FolderRole(name: "Jens' drop box") == .dropBox)
        #expect(FolderRole(name: "DROP BOX (private)") == .dropBox)
    }

    @Test("'upload' wins when both words appear")
    func uploadWinsOverDropBox() {
        #expect(FolderRole(name: "Upload Drop Box") == .upload)
    }

    @Test("RemotePath.containsDropBox is true for any component at or below a drop box")
    func containsDropBox() {
        #expect(RemotePath(components: ["Drop Box"]).containsDropBox)
        #expect(RemotePath(components: ["Public", "Drop Box", "Inner"]).containsDropBox)
        #expect(!RemotePath(components: ["Public", "Uploads"]).containsDropBox)
        #expect(!RemotePath().containsDropBox)
    }

    @Test("RemotePath.isUploadTarget is true under an upload folder or a drop box")
    func isUploadTarget() {
        #expect(RemotePath(components: ["Uploads"]).isUploadTarget)
        #expect(RemotePath(components: ["Uploads", "2026"]).isUploadTarget)
        #expect(RemotePath(components: ["Drop Box"]).isUploadTarget)
        #expect(!RemotePath(components: ["Software"]).isUploadTarget)
        #expect(!RemotePath().isUploadTarget)
    }
}
