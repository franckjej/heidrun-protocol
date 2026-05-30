import Testing
@testable import HeidrunCore

@Suite("HotlineError.fromWire — typed error decoding")
struct HotlineErrorFromWireTests {
    @Test("kind matching HotlineErrorKind.fileAlreadyExists produces .fileAlreadyExists")
    func decodesFileAlreadyExists() {
        let translated = HotlineError.fromWire(
            errorID: 1,
            kind: HotlineErrorKind.fileAlreadyExists.rawValue,
            message: "file 'notes.txt' already exists at this location"
        )
        guard case let .fileAlreadyExists(message) = translated else {
            Issue.record("expected .fileAlreadyExists, got \(translated)")
            return
        }
        #expect(message == "file 'notes.txt' already exists at this location")
    }

    @Test("nil kind falls back to .serverError so legacy servers still surface a useful error")
    func nilKindFallsBackToServerError() {
        let translated = HotlineError.fromWire(
            errorID: 1,
            kind: nil,
            message: "something went wrong"
        )
        guard case let .serverError(id, message) = translated else {
            Issue.record("expected .serverError, got \(translated)")
            return
        }
        #expect(id == 1)
        #expect(message == "something went wrong")
    }

    @Test("unknown kind falls back to .serverError rather than crashing")
    func unknownKindFallsBackToServerError() {
        let translated = HotlineError.fromWire(
            errorID: 1,
            kind: UInt16.max,
            message: "future error kind we don't recognise yet"
        )
        guard case let .serverError(id, message) = translated else {
            Issue.record("expected .serverError, got \(translated)")
            return
        }
        #expect(id == 1)
        #expect(message == "future error kind we don't recognise yet")
    }

    @Test("userMessage on .fileAlreadyExists capitalises the server's phrasing")
    func userMessageCapitalises() {
        let error = HotlineError.fileAlreadyExists(message: "file 'notes.txt' already exists at this location")
        #expect(error.userMessage == "File 'notes.txt' already exists at this location")
    }

    @Test("userMessage on .fileAlreadyExists supplies a default when the server omitted a message")
    func userMessageDefaultsWhenMessageMissing() {
        let error = HotlineError.fileAlreadyExists(message: nil)
        #expect(error.userMessage == "A file with that name already exists on the server.")
    }
}
