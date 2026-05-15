import Foundation
import Testing
@testable import HeidrunCore

@Suite("PartialDownloadURL")
struct PartialDownloadURLTests {
    @Test("partial appends the .heidrunpart suffix to a name with an extension")
    func appendsToNamedExtension() {
        let urls = PartialDownloadURL(
            finalDestination: URL(fileURLWithPath: "/tmp/downloads/report.pdf")
        )
        #expect(urls.final.path == "/tmp/downloads/report.pdf")
        #expect(urls.partial.path == "/tmp/downloads/report.pdf.heidrunpart")
    }

    @Test("partial appends the suffix to a name with no extension")
    func appendsToExtensionlessName() {
        let urls = PartialDownloadURL(
            finalDestination: URL(fileURLWithPath: "/tmp/downloads/README")
        )
        #expect(urls.partial.path == "/tmp/downloads/README.heidrunpart")
    }

    @Test("partial-to-final round-trip via finalDestination(forPartial:) strips the suffix")
    func partialToFinalStripsSuffix() {
        let partial = URL(fileURLWithPath: "/tmp/downloads/report.pdf.heidrunpart")
        let final = PartialDownloadURL.finalDestination(forPartial: partial)
        #expect(final?.path == "/tmp/downloads/report.pdf")
    }

    @Test("finalDestination(forPartial:) returns nil for non-partial URLs")
    func finalDestinationRejectsOther() {
        let other = URL(fileURLWithPath: "/tmp/downloads/report.pdf")
        #expect(PartialDownloadURL.finalDestination(forPartial: other) == nil)
    }

    @Test("isPartial recognises the suffix")
    func isPartialRecognisesSuffix() {
        let partial = URL(fileURLWithPath: "/tmp/x.dmg.heidrunpart")
        let other = URL(fileURLWithPath: "/tmp/x.dmg")
        #expect(PartialDownloadURL.isPartial(partial))
        #expect(!PartialDownloadURL.isPartial(other))
    }
}
