import Foundation
import Testing
@testable import HeidrunUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Suite("IconCatalog")
struct IconCatalogTests {
    @Test("catalog loads the bundled manifest with a non-trivial number of entries")
    func catalogIsPopulated() {
        // The legacy package has ~640 icons. Use a loose floor so adding /
        // removing a handful doesn't break the test.
        let entries = IconCatalog.shared.allEntries
        #expect(entries.count > 100, "expected many bundled icons, got \(entries.count)")
    }

    @Test("entries are returned sorted by id")
    func entriesAreSortedByID() {
        let ids = IconCatalog.shared.allEntries.map(\.id)
        #expect(ids == ids.sorted(), "allEntries should be ordered by ascending id")
    }

    @Test("entries have non-empty file names and positive dimensions")
    func entriesAreWellFormed() {
        for entry in IconCatalog.shared.allEntries.prefix(20) {
            #expect(!entry.file.isEmpty, "entry \(entry.id) has empty file")
            #expect(entry.width > 0)
            #expect(entry.height > 0)
        }
    }

    @Test("a known iconID resolves to a label")
    func knownIconHasLabel() {
        // 128 is the first user-visible icon in the legacy package
        // ("Storm trooper"). Just verify we get *some* label.
        let label = IconCatalog.shared.label(forID: 128)
        #expect(label != nil)
        #expect(label?.isEmpty == false)
    }

    #if canImport(AppKit)
    @Test("image(forID:) loads NSImage data for a known entry")
    func imageLoadsForKnownEntry() {
        guard let firstEntry = IconCatalog.shared.allEntries.first else {
            Issue.record("catalog has no entries to test against")
            return
        }
        let image = IconCatalog.shared.image(forID: firstEntry.id)
        #expect(image != nil, "expected image for id \(firstEntry.id)")
    }

    @Test("image(forID:) returns nil for an unknown id")
    func imageNilForUnknownID() {
        let image = IconCatalog.shared.image(forID: -99999)
        #expect(image == nil)
    }
    #endif
}
