import Foundation
import Testing
@testable import HeidrunCore

@Suite("PartialDownloadXattr")
struct PartialDownloadXattrTests {

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeidrunPartialXattrTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("foo.dmg.heidrunpart")
        try Data("partial bytes".utf8).write(to: url)
        return url
    }

    private func makeMetadata() -> PartialDownloadMetadata {
        PartialDownloadMetadata(
            serverAddress: "hotline.example.org",
            serverPort: 5500,
            serverLogin: "carol",
            serverName: "Example",
            remotePath: ["pub", "drops"],
            remoteFileName: "report.pdf",
            totalSize: 4_096,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("write then read round-trips the metadata")
    func writeReadRoundTrip() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let metadata = makeMetadata()
        try PartialDownloadXattr.write(metadata, to: url)
        let readBack = try PartialDownloadXattr.read(from: url)
        #expect(readBack == metadata)
    }

    @Test("read throws .xattrMissing when no attribute is present")
    func readMissingThrows() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: PartialDownloadMetadataError.xattrMissing) {
            _ = try PartialDownloadXattr.read(from: url)
        }
    }

    @Test("remove deletes the attribute; subsequent read throws .xattrMissing")
    func removeDeletes() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try PartialDownloadXattr.write(makeMetadata(), to: url)
        try PartialDownloadXattr.remove(from: url)
        #expect(throws: PartialDownloadMetadataError.xattrMissing) {
            _ = try PartialDownloadXattr.read(from: url)
        }
    }

    @Test("read throws .malformedJSON when the attribute holds garbage")
    func readMalformedThrows() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Write non-JSON bytes directly via setxattr.
        let bytes: [UInt8] = [0x00, 0x01, 0xFF, 0x42]
        try url.path.withCString { pathPointer in
            PartialDownloadXattr.attribute.withCString { namePointer in
                let result = bytes.withUnsafeBufferPointer { buffer in
                    setxattr(pathPointer, namePointer, buffer.baseAddress, buffer.count, 0, 0)
                }
                #expect(result == 0)
            }
        }
        #expect(throws: PartialDownloadMetadataError.malformedJSON) {
            _ = try PartialDownloadXattr.read(from: url)
        }
    }
}
