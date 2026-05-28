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
    /// `readLine()` so scripted usage keeps working.
    func readLine(prompt: String) -> String? {
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

            case 0x1b:                        // ESC — start of CSI/arrow sequence
                guard readOneByte() == 0x5b else { continue }       // '['
                guard let key = readOneByte() else { continue }
                switch key {
                case 0x41:                    // ↑ — older history
                    if historyIndex == 0 { savedDraft = buffer }
                    if historyIndex < history.count {
                        historyIndex += 1
                        buffer = Array(history[history.count - historyIndex].utf8)
                        cursor = buffer.count
                        redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                    }
                case 0x42:                    // ↓ — newer history (or back to draft)
                    if historyIndex > 0 {
                        historyIndex -= 1
                        buffer = historyIndex == 0
                            ? savedDraft
                            : Array(history[history.count - historyIndex].utf8)
                        cursor = buffer.count
                        redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                    }
                case 0x43:                    // → — cursor right
                    if cursor < buffer.count {
                        cursor += 1
                        write(Array("\u{1b}[C".utf8))
                    }
                case 0x44:                    // ← — cursor left
                    if cursor > 0 {
                        cursor -= 1
                        write(Array("\u{1b}[D".utf8))
                    }
                default:
                    break
                }

            default:
                if byte >= 0x20 || byte == 0x09 {     // printable ASCII + tab
                    buffer.insert(byte, at: cursor)
                    cursor += 1
                    redraw(prompt: prompt, buffer: buffer, cursor: cursor)
                }
                // Anything else (control chars we haven't bound) is dropped
                // silently — beats sending raw escapes into chat.
            }
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
            try? handle.seekToEnd()
            try? handle.write(contentsOf: row)
            try? handle.close()
        } else {
            try? row.write(to: url, options: .atomic)
        }
    }
}
