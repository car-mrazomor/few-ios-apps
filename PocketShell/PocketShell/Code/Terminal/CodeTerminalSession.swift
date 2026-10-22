import Observation
import SwiftTerm
import UIKit

/// The terminal tab: a SwiftTerm view, a readline-style line editor, and the bridge to the Python shell.
@MainActor @Observable
final class CodeTerminalSession {
    enum Mode {
        /// Waiting for a shell command.
        case command
        /// Python is running and not reading input; keys other than Ctrl-C are queued.
        case busy
        /// Python called input(); the line goes back to it.
        case input(LineRequest)
    }

    private(set) var mode: Mode = .busy
    var onOpenFile: ((URL) -> Void)?
    var onFilesChanged: (() -> Void)?

    @ObservationIgnored let view: ShellTerminalView
    @ObservationIgnored private let engine = PythonEngine.shared
    @ObservationIgnored private var line: [Character] = []
    @ObservationIgnored private var cursor = 0
    /// Terminal column where the editable text starts (after the prompt).
    @ObservationIgnored private var startColumn = 0
    @ObservationIgnored private var history: [String] = UserDefaults.standard.stringArray(forKey: "shellHistory") ?? []
    @ObservationIgnored private var inputHistory: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var savedLine: [Character] = []
    @ObservationIgnored private var typeahead: [UInt8] = []
    @ObservationIgnored private var escapeBuffer: [UInt8] = []
    @ObservationIgnored private var lastSize: (Int, Int) = (0, 0)

    init(fontSize: CGFloat) {
        view = ShellTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.installKeyBar(theme: .gruvbox)
        view.apply(theme: .gruvbox, fontSize: fontSize)
        view.terminalDelegate = self
        engine.console = self
    }

    func start() {
        engine.start()
        Task {
            if let error = engine.startupError {
                write("\u{1B}[31mPython failed to start: \(error)\u{1B}[0m\r\n")
                return
            }
            _ = await engine.call("set_size", "\(lastSize.0 > 0 ? lastSize.0 : 80) \(lastSize.1 > 0 ? lastSize.1 : 24)")
            write("\u{1B}[38;2;146;131;116mPocketCode · Python 3.13 · type 'help' for commands\u{1B}[0m\r\n")
            await showPrompt()
        }
    }

    // MARK: Running commands

    /// Runs a command as if typed (used by the editor's Run button and the file browser).
    func run(_ command: String) {
        guard case .command = mode else { return }
        write(command)
        submitCommand(command)
    }

    func interrupt() {
        switch mode {
        case .busy:
            engine.interrupt()
        case .input(let request):
            write("^C\r\n")
            mode = .busy
            request.interrupt()
        case .command:
            write("^C\r\n")
            Task { await showPrompt() }
        }
    }

    private func submitCommand(_ text: String) {
        write("\r\n")
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != history.last {
            history.append(trimmed)
            if history.count > 500 { history.removeFirst(history.count - 500) }
            UserDefaults.standard.set(history, forKey: "shellHistory")
        }
        mode = .busy
        Task {
            _ = await engine.run(text)
            await showPrompt()
            onFilesChanged?()
        }
    }

    private func showPrompt() async {
        let prompt = await engine.call("prompt") ?? "❯ "
        write(prompt.replacingOccurrences(of: "\n", with: "\r\n"))
        beginEditing(history: history)
        mode = .command
        replayTypeahead()
    }

    // MARK: Line editing

    private func beginEditing(history: [String]) {
        line = []
        cursor = 0
        historyIndex = nil
        startColumn = view.getTerminal().getCursorLocation().x
    }

    private var activeHistory: [String] {
        if case .input = mode { return inputHistory }
        return history
    }

    private func submit() {
        let text = String(line)
        moveCursor(to: line.count)
        switch mode {
        case .command:
            submitCommand(text)
        case .input(let request):
            write("\r\n")
            if !text.isEmpty, text != inputHistory.last { inputHistory.append(text) }
            mode = .busy
            request.complete(line: text)
        case .busy:
            break
        }
    }

    private func handle(_ bytes: [UInt8]) {
        if case .busy = mode {
            for byte in bytes {
                if byte == 0x03 {
                    engine.interrupt()
                    typeahead.removeAll()
                } else {
                    typeahead.append(byte)
                }
            }
            return
        }

        var text = ""
        func flushText() {
            if !text.isEmpty { insert(text); text = "" }
        }

        var index = 0
        let input = escapeBuffer + bytes
        escapeBuffer = []
        while index < input.count {
            let byte = input[index]
            if byte == 0x1B {
                flushText()
                // Collect an escape sequence: ESC [ ... final, or ESC O x.
                var end = index + 1
                if end < input.count, input[end] == UInt8(ascii: "[") || input[end] == UInt8(ascii: "O") {
                    end += 1
                    while end < input.count, !(0x40...0x7E).contains(input[end]) { end += 1 }
                }
                if end >= input.count {
                    // A bare Esc (key bar) means nothing at a prompt; a cut-off sequence waits for the rest.
                    if index + 1 < input.count { escapeBuffer = Array(input[index...]) }
                    return
                }
                handleEscape(Array(input[(index + 1)...end]))
                index = end + 1
                continue
            }
            if byte < 0x20 || byte == 0x7F {
                flushText()
                handleControl(byte)
                if case .busy = mode {
                    typeahead.append(contentsOf: input[(index + 1)...])
                    return
                }
            } else {
                // Collect the full UTF-8 sequence.
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if index + length > input.count {
                    escapeBuffer = Array(input[index...])
                    break
                }
                text += String(decoding: input[index..<(index + length)], as: UTF8.self)
                index += length - 1
            }
            index += 1
        }
        flushText()
    }

    private func handleControl(_ byte: UInt8) {
        switch byte {
        case 0x0D, 0x0A: submit()
        case 0x7F, 0x08:  // Backspace
            guard cursor > 0 else { return }
            line.remove(at: cursor - 1)
            redraw(cursorAt: cursor - 1)
        case 0x01: moveCursor(to: 0)  // Ctrl-A
        case 0x05: moveCursor(to: line.count)  // Ctrl-E
        case 0x02: moveCursor(to: max(0, cursor - 1))  // Ctrl-B
        case 0x06: moveCursor(to: min(line.count, cursor + 1))  // Ctrl-F
        case 0x15:  // Ctrl-U
            line.removeFirst(cursor)
            redraw(cursorAt: 0)
        case 0x0B:  // Ctrl-K
            line.removeLast(line.count - cursor)
            redraw(cursorAt: cursor)
        case 0x17:  // Ctrl-W
            var start = cursor
            while start > 0, line[start - 1] == " " { start -= 1 }
            while start > 0, line[start - 1] != " " { start -= 1 }
            line.removeSubrange(start..<cursor)
            redraw(cursorAt: start)
        case 0x0C:  // Ctrl-L
            let saved = line, position = cursor
            write("\u{1B}[2J\u{1B}[3J\u{1B}[H")
            if case .command = mode {
                Task {
                    await showPrompt()
                    insert(String(saved))
                    moveCursor(to: position)
                }
            }
        case 0x03: interrupt()  // Ctrl-C
        case 0x04:  // Ctrl-D
            guard line.isEmpty else { return }
            if case .input(let request) = mode {
                write("\r\n")
                mode = .busy
                request.complete(line: nil)
            }
        case 0x09: complete()  // Tab
        default: break
        }
    }

    private func handleEscape(_ sequence: [UInt8]) {
        let code = String(decoding: sequence, as: UTF8.self)
        switch code {
        case "[A", "OA": recallHistory(older: true)
        case "[B", "OB": recallHistory(older: false)
        case "[C", "OC": moveCursor(to: min(line.count, cursor + 1))
        case "[D", "OD": moveCursor(to: max(0, cursor - 1))
        case "[H", "OH", "[1~": moveCursor(to: 0)
        case "[F", "OF", "[4~": moveCursor(to: line.count)
        case "[3~":  // Delete
            guard cursor < line.count else { return }
            line.remove(at: cursor)
            redraw(cursorAt: cursor)
        case "[1;5D", "[1;3D", "b":  // word left
            var position = cursor
            while position > 0, line[position - 1] == " " { position -= 1 }
            while position > 0, line[position - 1] != " " { position -= 1 }
            moveCursor(to: position)
        case "[1;5C", "[1;3C", "f":  // word right
            var position = cursor
            while position < line.count, line[position] == " " { position += 1 }
            while position < line.count, line[position] != " " { position += 1 }
            moveCursor(to: position)
        default: break
        }
    }

    private func insert(_ text: String) {
        // Pasted multi-line text: submit line by line.
        if text.contains(where: \.isNewline) {
            let parts = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (i, part) in parts.enumerated() {
                insert(String(part))
                if i < parts.count - 1 {
                    submit()
                    if case .busy = mode {
                        typeahead.append(contentsOf: Array(parts[(i + 1)...].joined(separator: "\n").utf8))
                        return
                    }
                }
            }
            return
        }
        line.insert(contentsOf: Array(text), at: cursor)
        redraw(cursorAt: cursor + text.count)
    }

    private func recallHistory(older: Bool) {
        let items = activeHistory
        guard !items.isEmpty else { return }
        if historyIndex == nil {
            guard older else { return }
            savedLine = line
            historyIndex = items.count
        }
        var index = historyIndex! + (older ? -1 : 1)
        index = max(0, min(items.count, index))
        historyIndex = index
        line = index == items.count ? savedLine : Array(items[index])
        redraw(cursorAt: line.count, from: cursor)
    }

    private func complete() {
        guard case .command = mode else {
            insert("    ")
            return
        }
        let current = String(line[..<cursor])
        let rest = String(line[cursor...])
        mode = .busy
        Task {
            let completed = await engine.call("complete", current) ?? current
            mode = .command
            if completed == current { return }
            line = Array(completed + rest)
            redraw(cursorAt: completed.count)
        }
    }

    // MARK: Rendering

    private var columns: Int { max(1, view.getTerminal().cols) }

    private func position(_ offset: Int) -> (row: Int, column: Int) {
        let absolute = startColumn + offset
        return (absolute / columns, absolute % columns)
    }

    /// Moves the terminal cursor between two offsets in the edited line, across wrapped rows.
    private func moveSequence(from: Int, to: Int) -> String {
        let a = position(from), b = position(to)
        var sequence = ""
        if b.row < a.row { sequence += "\u{1B}[\(a.row - b.row)A" }
        if b.row > a.row { sequence += "\u{1B}[\(b.row - a.row)B" }
        sequence += "\u{1B}[\(b.column + 1)G"
        return sequence
    }

    private func moveCursor(to offset: Int) {
        guard offset != cursor else { return }
        write(moveSequence(from: cursor, to: offset))
        cursor = offset
    }

    private func redraw(cursorAt newCursor: Int, from oldCursor: Int? = nil) {
        var output = moveSequence(from: oldCursor ?? cursor, to: 0)
        output += "\u{1B}[J" + String(line)
        // At an exact row boundary the terminal defers wrapping; force it so row math stays right.
        if !line.isEmpty, (startColumn + line.count) % columns == 0 { output += " \r" }
        output += moveSequence(from: line.count, to: newCursor)
        write(output)
        cursor = newCursor
    }

    private func replayTypeahead() {
        guard !typeahead.isEmpty else { return }
        let pending = typeahead
        typeahead = []
        handle(pending)
    }

    private func write(_ text: String) {
        view.feed(text: text)
        #if DEBUG
        Self.transcript?(text)
        #endif
    }

    #if DEBUG
    /// Debug-only mirror of everything shown in the terminal (see CodeDebugLaunch).
    static var transcript: ((String) -> Void)?
    #endif
}

// MARK: - Python console

extension CodeTerminalSession: PythonConsole {
    func pythonWrote(_ text: String, isError: Bool) {
        var output = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if isError, !output.contains("\u{1B}[") {
            output = "\u{1B}[38;2;251;73;52m" + output + "\u{1B}[0m"
        }
        write(output)
    }

    func pythonWantsLine(_ request: LineRequest) {
        mode = .input(request)
        beginEditing(history: inputHistory)
        replayTypeahead()
    }

    func pythonEvent(_ name: String, payload: String) {
        switch name {
        case "open": onOpenFile?(URL(fileURLWithPath: payload))
        case "files": onFilesChanged?()
        default: break
        }
    }
}

// MARK: - TerminalViewDelegate

extension CodeTerminalSession: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { handle(bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            lastSize = (newCols, newRows)
            if case .command = mode {
                Task { _ = await engine.call("set_size", "\(newCols) \(newRows)") }
            }
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme) else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { UIPasteboard.general.string = text }
    }

    nonisolated func bell(source: TerminalView) {}
}
