import Foundation
import Testing
@testable import HeidrunCore

@Suite("PartialDownloadMetadata")
struct PartialDownloadMetadataTests {
    @Test("schema version defaults to 1 via the convenience initialiser")
    func defaultSchemaVersionIsOne() {
        let metadata = PartialDownloadMetadata(
            serverAddress: "hotline.example.org",
            serverPort: 5500,
            serverLogin: "",
            serverName: "Test",
            remotePath: ["pub", "drops"],
            remoteFileName: "report.pdf",
            totalSize: 1024
        )
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.serverAddress == "hotline.example.org")
        #expect(metadata.remotePath == ["pub", "drops"])
        #expect(metadata.totalSize == 1024)
    }

    @Test("init(seed:) plumbs the seed identity into the full struct")
    func seedInitPlumbsIdentity() {
        let seed = PartialDownloadMetadata.SeedFields(
            serverAddress: "h.example.org",
            serverPort: 5500,
            serverLogin: "anon",
            serverName: "Example"
        )
        let metadata = PartialDownloadMetadata(
            seed: seed,
            remotePath: ["pub"],
            remoteFileName: "foo.bin",
            totalSize: 42
        )
        #expect(metadata.serverAddress == "h.example.org")
        #expect(metadata.serverName == "Example")
        #expect(metadata.remoteFileName == "foo.bin")
        #expect(metadata.totalSize == 42)
        #expect(metadata.schemaVersion == 1)
    }

    @Test("JSON round-trip preserves every field")
    func jsonRoundTrip() throws {
        let original = PartialDownloadMetadata(
            serverAddress: "hotline.example.org",
            serverPort: 5500,
            serverLogin: "carol",
            serverName: "Example",
            remotePath: ["pub", "drops"],
            remoteFileName: "report.pdf",
            totalSize: 1024,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PartialDownloadMetadata.self, from: encoded)
        #expect(decoded == original)
    }
}

@Suite("PartialDownloadMetadataError")
struct PartialDownloadMetadataErrorTests {
    @Test("unsupportedSchema carries the offending version")
    func unsupportedSchemaCarriesVersion() {
        let error = PartialDownloadMetadataError.unsupportedSchema(version: 99)
        if case let .unsupportedSchema(version) = error {
            #expect(version == 99)
        } else {
            Issue.record("expected .unsupportedSchema")
        }
    }

    @Test("xattrUnreadable equality compares the message")
    func xattrUnreadableEqualityComparesMessage() {
        let same1 = PartialDownloadMetadataError.xattrUnreadable(message: "permission denied")
        let same2 = PartialDownloadMetadataError.xattrUnreadable(message: "permission denied")
        let different = PartialDownloadMetadataError.xattrUnreadable(message: "i/o error")
        #expect(same1 == same2)
        #expect(same1 != different)
    }
}
