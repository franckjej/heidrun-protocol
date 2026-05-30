// SPDX-License-Identifier: MIT
//
// Minimal raw-mode line editor for the heidrun REPL: arrow keys for
// history, basic in-line editing (left/right cursor + backspace),
// optional `~/.heidrun_history` persistence. Pure Swift on POSIX
// termios — works on macOS + Linux without any external dependency.
//
// Why custom rather than linenoise-swift: that package hasn't seen a
// commit since 2021 and is at tag 0.0.3, so pulling it in risks
// Swift-6 concurrency adaptation work without a maintainer in the
// loop. ~150 LOC is cheaper than that risk.
//
// Known limitation: cursor positions are tracked in bytes, not
// graphemes. ASCII chat works correctly; multi-byte input (emoji,
// non-Latin scripts) renders but cursor math is off. Acceptable for
// v1, revisit if international input becomes a need.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class LineEditor {
    private var history: [String] = []
    private let historyURL: URL?

    /// 0 = live draft, 1..history.count = recall index from end.
    private var historyIndex: Int = 0
    /// Whatever the user had typed before they started pressing ↑.
    private var savedDraft: [UInt8] = []

    /// TAB-completion callback. The editor invokes this when the
    /// buffer starts with `/` (so chat lines don't trigger it) and
    /// passes the full context — which word the user is editing
    /// and whether that word is the command itself (first word
    /// after `/`) or an argument. The callback returns the full
    /// replacements for `currentWord` (just the word, not the full
    /// line), and is `async` because argument completion typically
    /// queries the live server. Nil disables completion entirely.
    var completion: ((_ context: CompletionContext) async -> [String])?

    /// Context handed to the `completion` callback so it can pick
    /// the right completion strategy. `fullLine` is everything from
    /// the start of the buffer up to the cursor (without the
    /// leading `/`); `currentWord` is the word being completed
    /// (everything from the last space to the cursor); `isFirstWord`
    /// flags command-name vs argument completion.
    struct CompletionContext: Sendable {
        public let fullLine: String
        public let currentWord: String
        public let isFirstWord: Bool
    }

    private static let supportsRawMode: Bool = {
        guard let term = ProcessInfo.processInfo.environment["TERM"] else { return false }
        return !term.isEmpty && term != "dumb"
    }()

    init(historyURL: URL? = nil) {
        self.historyURL = historyURL
        if let url = historyURL,
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            history = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    /// Read one line of input with editing. Returns `nil` on EOF
    /// (Ctrl-D on an empty line) or when stdin isn't a TTY (e.g. when
    /// piped) — in the latter case we fall back to Foundation's
    /// `readLine()` so scripted usage keeps working. `async` because
    /// the TAB-completion callback may itself await server queries.
    func readLine(prompt: String) async -> String? {
        if !LineEditor.supportsRawMode || isatty(STDIN_FILENO) == 0 {
            FileHandle.standardError.write(Data(prompt.utf8))
            return Swift.readLine(strippingNewline: true)
        }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        var raw = original
        cfmakeraw(&raw)
        // cfmakeraw turns OPOST off, which kills the kernel's automatic
        // NL → CR-NL translation. That's catastrophic for our REPL: the
        // event-printer task writes "message\n" while we're in raw mode,
        // and without OPOST the cursor moves down a row but stays in the
        // same column — every chat line steps further right than the last.
        // Re-enable OPOST + ONLCR so `\n` printed from anywhere in the
        // process still does what callers expect.
        raw.c_oflag |= tcflag_t(OPOST | ONLCR)
        guard tcsetattr(STDIN_FILENO, TCSADRAIN, &raw) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        defer { _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &original) }

        write(Array(prompt.utf8))

        var buffer: [UInt8] = []
        var cursor = 0
        historyIndex = 0
        savedDraft = []

        while true {
            guard let byte = readOneByte() else {
                write(Array("\r\n".utf8))
                return nil
            }
            switch byte {
            case 0x0d, 0x0a:                  // CR / LF — submit
                write(Array("\r\n".utf8))
                let line = String(decoding: buffer, as: UTF8.self)
                if !line.isEmpty, line != history.last {
                    history.append(line)
                    appendHistoryFile(line)
                }
                return line

            case 0x04:                        // Ctrl-D
                if buffer.isEmpty {
                    write(Array("\r\n".utf8))
                    return nil
                }
                if cursor < buffer.count {
                    buffer.remove(at: cursor)
                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                }

            case 0x03:                        // Ctrl-C — cancel current line
                write(Array("\r\n".utf8))
                return ""

            case 0x7f, 0x08:                  // Backspace / DEL
                if cursor > 0 {
                    buffer.remove(at: cursor - 1)
                    cursor -= 1
                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                }

            case 0x1b:                        // ESC — start of CSI / Meta sequence
                // Two flavours we care about:
                //   ESC [ <code>          — bare arrow keys + CSI 1; <mod> X
                //                            forms for Alt-/Ctrl-arrow.
                //   ESC <letter>          — readline-style Meta keys, where
                //                            Alt acts as a meta prefix
                //                            (iTerm "Option as Meta", xterm
                //                            metaSendsEscape). M-b / M-f
                //                            jump word-back / word-forward.
                guard let after = readOneByte() else { continue }
                if after == 0x5b {                                 // '['
                    guard let key = readOneByte() else { continue }
                    switch key {
                    case 0x41:                                     // ↑ — older history
                        if historyIndex == 0 { savedDraft = buffer }
                        if historyIndex < history.count {
                            historyIndex += 1
                            buffer = Array(history[history.count - historyIndex].utf8)
                            cursor = buffer.count
                            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                        }
                    case 0x42:                                     // ↓ — newer history (or back to draft)
                        if historyIndex > 0 {
                            historyIndex -= 1
                            buffer = historyIndex == 0
                                ? savedDraft
                                : Array(history[history.count - historyIndex].utf8)
                            cursor = buffer.count
                            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                        }
                    case 0x43:                                     // → — cursor right (one char)
                        if cursor < buffer.count {
                            cursor += 1
                            write(Array("\u{1b}[C".utf8))
                        }
                    case 0x44:                                     // ← — cursor left (one char)
                        if cursor > 0 {
                            cursor -= 1
                            write(Array("\u{1b}[D".utf8))
                        }
                    case 0x31:
                        // CSI 1 ; <modifier> <letter> — modified arrows.
                        // Alt-arrow ⇒ modifier 3, Ctrl-arrow ⇒ modifier 5.
                        // We treat both as "by-word" jumps (xterm + most
                        // modern terminals; matches readline's M-b/M-f and
                        // bash's word-by-word behaviour).
                        guard readOneByte() == 0x3b else { continue }      // ';'
                        guard readOneByte() != nil else { continue }       // modifier digit — accept any
                        guard let modifiedKey = readOneByte() else { continue }
                        switch modifiedKey {
                        case 0x43:                                 // Alt/Ctrl+→
                            jumpWordForward(buffer: buffer, cursor: &cursor)
                            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                        case 0x44:                                 // Alt/Ctrl+←
                            jumpWordBack(buffer: buffer, cursor: &cursor)
                            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                        default:
                            break
                        }
                    default:
                        break
                    }
                } else if after == 0x62 {                          // M-b — word back (readline)
                    jumpWordBack(buffer: buffer, cursor: &cursor)
                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                } else if after == 0x66 {                          // M-f — word forward (readline)
                    jumpWordForward(buffer: buffer, cursor: &cursor)
                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                }
                // Any other ESC-sequence is dropped silently — better
                // than echoing raw bytes into chat.

            case 0x09:                        // TAB — completion
                await handleTabCompletion(
                    buffer: &buffer,
                    cursor: &cursor,
                    prompt: prompt
                )

            default:
                if byte >= 0x20 {                 // printable ASCII
                    buffer.insert(byte, at: cursor)
                    cursor += 1
                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                }
                // Anything else (control chars we haven't bound) is dropped
                // silently — beats sending raw escapes into chat.
            }
        }
    }

    // MARK: - TAB completion

    /// TAB handler: complete the word at the cursor via the
    /// `completion` callback. No-op for chat lines (so TAB just
    /// drops in mid-chat rather than echoing a literal `\t`).
    /// Splices on a single match, extends to the longest common
    /// prefix on multiple, dumps the candidate list when there's
    /// no common extension — bash-style.
    private func handleTabCompletion(buffer: inout [UInt8], cursor: inout Int, prompt: String) async {
        guard let completion else { return }
        let beforeCursor = String(decoding: buffer[..<cursor], as: UTF8.self)
        // `//foo` escape-prefix means "send literally as chat" — no
        // completion. Plain chat lines (no leading `/`) likewise.
        guard beforeCursor.hasPrefix("/"), !beforeCursor.hasPrefix("//") else { return }
        let afterSlash = String(beforeCursor.dropFirst())
        // The currentWord is everything from the last space (or
        // start) to the cursor. `isFirstWord` flags whether that
        // word is the command name itself or an argument.
        let lastSpace = afterSlash.lastIndex(of: " ")
        let currentWord: String
        let isFirstWord: Bool
        if let lastSpace {
            currentWord = String(afterSlash[afterSlash.index(after: lastSpace)...])
            isFirstWord = false
        } else {
            currentWord = afterSlash
            isFirstWord = true
        }
        let context = CompletionContext(
            fullLine: afterSlash,
            currentWord: currentWord,
            isFirstWord: isFirstWord
        )
        let matches = await completion(context).sorted()
        if matches.isEmpty { return }
        if matches.count == 1 {
            guard matches[0].hasPrefix(currentWord) else { return }
            // Splice in the suffix + a trailing space so the user
            // can immediately start typing the next argument. Path
            // completions that should NOT auto-trail (e.g. an open
            // folder the user wants to descend into) can return the
            // completion with a trailing `/` and the caller spots
            // the trailing-`/` and omits the space — handled below.
            let trailingSlash = matches[0].hasSuffix("/")
            let suffix = String(matches[0].dropFirst(currentWord.count))
                + (trailingSlash ? "" : " ")
            let suffixBytes = Array(suffix.utf8)
            buffer.insert(contentsOf: suffixBytes, at: cursor)
            cursor += suffixBytes.count
            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
            return
        }
        // Multiple matches: bash-style — first TAB extends to the
        // longest common prefix; if there's no extension, dump the
        // candidate list on a new line and re-draw the prompt.
        let commonPrefix = Self.longestCommonPrefix(of: matches)
        if commonPrefix.count > currentWord.count {
            let suffix = String(commonPrefix.dropFirst(currentWord.count))
            let suffixBytes = Array(suffix.utf8)
            buffer.insert(contentsOf: suffixBytes, at: cursor)
            cursor += suffixBytes.count
            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
        } else {
            write(Array("\r\n".utf8))
            // Display matches with a leading `/` only for command
            // names (so the listing reads like the prompt would);
            // path arguments are listed bare.
            let listing = isFirstWord
                ? matches.map { "/\($0)" }.joined(separator: "  ")
                : matches.joined(separator: "  ")
            write(Array(listing.utf8))
            write(Array("\r\n".utf8))
            redraw(prompt: prompt, buffer: buffer, cursor: cursor)
        }
    }

    private static func longestCommonPrefix(of strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefixEnd = first.endIndex
        for other in strings.dropFirst() {
            var firstIndex = first.startIndex
            var otherIndex = other.startIndex
            while firstIndex < prefixEnd,
                  otherIndex < other.endIndex,
                  first[firstIndex] == other[otherIndex] {
                first.formIndex(after: &firstIndex)
                other.formIndex(after: &otherIndex)
            }
            prefixEnd = firstIndex
            if prefixEnd == first.startIndex { return "" }
        }
        return String(first[..<prefixEnd])
    }

    // MARK: - Word navigation

    /// Move the cursor left to the start of the previous word.
    /// Word = a run of non-whitespace bytes. Skip trailing whitespace
    /// first so a cursor that sits right after a word jumps over the
    /// space and lands at the word's start — matches readline's M-b.
    private func jumpWordBack(buffer: [UInt8], cursor: inout Int) {
        while cursor > 0, Self.isWordSeparator(buffer[cursor - 1]) {
            cursor -= 1
        }
        while cursor > 0, !Self.isWordSeparator(buffer[cursor - 1]) {
            cursor -= 1
        }
    }

    /// Move the cursor right to the end of the next word. Skip leading
    /// whitespace, then walk through the word — matches readline's M-f.
    private func jumpWordForward(buffer: [UInt8], cursor: inout Int) {
        while cursor < buffer.count, Self.isWordSeparator(buffer[cursor]) {
            cursor += 1
        }
        while cursor < buffer.count, !Self.isWordSeparator(buffer[cursor]) {
            cursor += 1
        }
    }

    private static func isWordSeparator(_ byte: UInt8) -> Bool {
        // Space, tab, and common punctuation. Anything else is part of
        // a word. Matches most readline configurations closely enough
        // for chat — a word is the run between separators.
        switch byte {
        case 0x20, 0x09:           // space, tab
            return true
        default:
            return false
        }
    }

    // MARK: - termios I/O helpers

    private func readOneByte() -> UInt8? {
        var byte: UInt8 = 0
        let n = Foundation.read(STDIN_FILENO, &byte, 1)
        return n == 1 ? byte : nil
    }

    private func write(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { buffer in
            Foundation.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
    }

    /// Redraw the whole prompt + current buffer, then place the cursor
    /// where logically it should sit. Cheap enough for human-typing
    /// speeds; avoids the bookkeeping of incremental redraws.
    private func redraw(prompt: String, buffer: [UInt8], cursor: Int) {
        write(Array("\r".utf8))                       // home
        write(Array(prompt.utf8))
        write(buffer)
        write(Array("\u{1b}[K".utf8))                 // clear to EOL
        let trailing = buffer.count - cursor
        if trailing > 0 {
            write(Array("\u{1b}[\(trailing)D".utf8))  // move cursor back
        }
    }

    // MARK: - History persistence

    private func appendHistoryFile(_ line: String) {
        guard let url = historyURL else { return }
        let row = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            // Best-effort persistence — history is convenience, not
            // correctness. The discards silence the "result of 'try?'
            // is unused" warning (0 warnings per commit, per project
            // convention).
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: row)
            _ = try? handle.close()
        } else {
            _ = try? row.write(to: url, options: .atomic)
        }
    }
}
