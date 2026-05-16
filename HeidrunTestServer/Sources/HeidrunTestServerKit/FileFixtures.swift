import Foundation
import HeidrunCore

/// Initial contents the test server hands out to fresh listings.
public enum FileFixtures {
    /// Build a stock tree resembling the legacy "Heidrun Project" file
    /// listing in `Homepage/screenshots/screenshot3.jpg` (root folder,
    /// a couple of nested folders, and a small file or two for
    /// download tests).
    public static func makeRoot() -> VFS {
        let vfs = VFS()
        vfs.putFile(
            at: [],
            name: "README.txt",
            data: Data("Welcome to the Heidrun test server.\n".utf8),
            type: "TEXT",
            creator: "ttxt"
        )
        vfs.putFile(
            at: [],
            name: "lipsum.bin",
            data: Data((0..<4096).map { UInt8($0 & 0xFF) }),
            type: "BINA"
        )
        vfs.createFolder(at: [], name: "Development Builds")
        vfs.createFolder(at: [], name: "Icon Packages")
        vfs.putFile(
            at: ["Development Builds"],
            name: "heidrun_065.dmg",
            data: Data(repeating: 0xAB, count: 8192),
            type: "DMGf"
        )
        // Big-enough fixture so a `kill -9` mid-transfer leaves a
        // meaningfully-sized `.heidrunpart` on disk for the resume smoke
        // path. Sits in RAM while the server is running — fine for a
        // manually-launched fixture, not for CI.
        vfs.putFile(
            at: [],
            name: "large-resume-test.bin",
            data: Data(repeating: 0x55, count: 300 * 1024 * 1024),
            type: "BINA"
        )
        return vfs
    }
}
