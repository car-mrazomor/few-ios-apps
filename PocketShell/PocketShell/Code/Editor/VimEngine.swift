import Runestone
import UIKit

/// A vim emulation layer over Runestone's TextView: the commonly used subset of normal, visual,
/// insert and command-line modes. Offsets are UTF-16 (NSString), like Runestone's NSRange API.
@MainActor
final class VimEngine {
    enum Mode: Equatable {
        case normal, insert, visual, visualLine, command, search(forward: Bool)

        var label: String {
            switch self {
            case .normal: "NORMAL"
            case .insert: "INSERT"
            case .visual: "VISUAL"
            case .visualLine: "V-LINE"
            case .command: "COMMAND"
            case .search: "SEARCH"
            }
        }
    }

    // MARK: Outputs to the editor UI

    var onStateChange: (() -> Void)?
    var onCommand: ((String) -> Void)?  // ":w", ":q" etc. that the editor handles

    private(set) var mode: Mode = .normal
    /// Text typed after ":" or "/".
    private(set) var commandLine = ""
    private(set) var message: String?
    /// Pending keys shown in the status line (like vim's showcmd).
    var pendingKeys: String { (count.map(String.init) ?? "") + pending }

    private weak var textView: TextView?

    private var count: Int?
    private var pending = ""
    private var desiredColumn: Int?
    private var visualAnchor = 0
    private var register = ""
    private var registerLinewise = false
    private var lastSearch: (pattern: String, forward: Bool)?
    private var commandHistory: [String] = []

    // Dot-repeat: keys of the last change, and the keys of the change being recorded.
    private var lastChange: [String] = []
    private var recording: [String]?
    private var replaying = false

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: Text helpers

    private var text: NSString { (textView?.text ?? "") as NSString }
    private var length: Int { text.length }

    private var isVisual: Bool { mode == .visual || mode == .visualLine }

    private var caret: Int {
        get { isVisual ? visualCursor : (textView?.selectedRange.location ?? 0) }
        set {
            textView?.selectedRange = NSRange(location: max(0, min(newValue, length)), length: 0)
            updateBlockCursor()
        }
    }

    private func lineStart(_ location: Int) -> Int {
        text.lineRange(for: NSRange(location: min(location, length), length: 0)).location
    }

    /// Offset of the newline ending this line (or end of text).
    private func lineEnd(_ location: Int) -> Int {
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: min(location, length), length: 0))
        return end
    }

    /// Last character position a normal-mode cursor may occupy on this line.
    private func lastColumn(_ location: Int) -> Int {
        max(lineStart(location), lineEnd(location) - 1)
    }

    private func char(_ location: Int) -> unichar? {
        location >= 0 && location < length ? text.character(at: location) : nil
    }

    private func isNewline(_ c: unichar?) -> Bool { c == 10 || c == 13 }

    private func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) || c == 95
    }

    private func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    private func charClass(_ c: unichar) -> Int { isSpace(c) ? 0 : isWordChar(c) ? 1 : 2 }

    private func column(_ location: Int) -> Int { location - lineStart(location) }

    private func firstNonBlank(_ location: Int) -> Int {
        var position = lineStart(location)
        let end = lineEnd(location)
        while position < end, let c = char(position), c == 32 || c == 9 { position += 1 }
        return position
    }

    /// Start offset of the line `delta` lines away (clamped).
    private func lineStart(from location: Int, delta: Int) -> Int {
        var position = lineStart(location)
        if delta > 0 {
            for _ in 0..<delta {
                let end = lineEnd(position)
                guard end < length else { break }
                position = text.lineRange(for: NSRange(location: position, length: 0)).upperBound
            }
        } else {
            for _ in 0..<(-delta) {
                guard position > 0 else { break }
                position = lineStart(position - 1)
            }
        }
        return position
    }

    // MARK: Editing primitives (all go through TextView so undo works)

    private func replace(_ range: NSRange, with string: String) {
        if let textView = textView as? VimTextView {
            textView.applyEdit(range, with: string)
        } else {
            textView?.replace(range, withText: string)
        }
    }

    private func yank(_ range: NSRange, linewise: Bool) {
        var content = text.substring(with: range)
        if linewise {
            // Deleting the last line takes the newline before it; store it as a normal "line\n".
            if content.hasPrefix("\n") { content = String(content.dropFirst()) + "\n" }
            if !content.hasSuffix("\n") { content += "\n" }
        }
        register = content
        registerLinewise = linewise
        UIPasteboard.general.string = register
    }

    // MARK: Key input

    /// Feeds one key. Special keys: "<Esc>", "<CR>", "<BS>", "<C-r>", "<C-d>", "<C-u>", "<Tab>".
    func handle(_ key: String) {
        message = nil
        if recording != nil, !replaying { recording?.append(key) }

        switch mode {
        case .insert:
            if key == "<Esc>" { exitInsert() }
        case .command, .search:
            handleCommandLine(key)
        case .normal, .visual, .visualLine:
            handleNormal(key)
        }
        onStateChange?()
    }

    /// Insert-mode text typed on the keyboard (inserted by TextView itself); recorded for ".".
    func noteInserted(_ text: String, deleted: Bool) {
        guard mode == .insert, recording != nil, !replaying else { return }
        recording?.append(deleted ? "<BS>" : "i:" + text)
    }

    func enterInsertFromTap() {
        guard mode != .insert else { return }
        setMode(.insert)
    }

    // MARK: Mode changes

    private func setMode(_ newMode: Mode) {
        mode = newMode
        if newMode != .insert, newMode != .visual, newMode != .visualLine {
            clampToLine()
        }
        updateBlockCursor()
    }

    private func startInsert(at location: Int) {
        caret = location
        setMode(.insert)
    }

    private func exitInsert() {
        let location = caret
        setMode(.normal)
        if location > lineStart(location) { caret = location - 1 }
        finishChange()
    }

    private func beginChange(_ key: String) {
        guard !replaying, recording == nil else { return }
        recording = (count.map { String($0).map(String.init) } ?? []) + pending.map(String.init) + [key]
    }

    private func finishChange() {
        if let recorded = recording, !replaying { lastChange = recorded }
        recording = nil
    }

    private func clampToLine() {
        guard let textView else { return }
        let location = textView.selectedRange.location
        let last = lastColumn(location)
        if location > last { textView.selectedRange = NSRange(location: last, length: 0) }
    }

    /// Normal mode has no block caret in Runestone; tint the character under the cursor instead.
    func updateBlockCursor() {
        guard let textView else { return }
        var ranges = textView.highlightedRanges.filter { $0.id != "vim.cursor" }
        if mode == .normal, length > 0 {
            let location = min(textView.selectedRange.location, length - 1)
            if !isNewline(char(location)) {
                ranges.append(HighlightedRange(id: "vim.cursor", range: NSRange(location: location, length: 1),
                                               color: Gruvbox.fg.withAlphaComponent(0.55)))
            }
        }
        textView.highlightedRanges = ranges
        textView.insertionPointColor = mode == .insert ? Gruvbox.fg : .clear
    }

    // MARK: Normal & visual mode

    private func handleNormal(_ key: String) {
        if key == "<Esc>" {
            count = nil
            pending = ""
            recording = nil
            if mode != .normal {
                let location = caret
                setMode(.normal)
                caret = location
            }
            return
        }

        // Counts.
        if pending.isEmpty || (pending.count == 1 && "dcy><".contains(pending)),
           let digit = Int(key), digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return
        }

        // Second key of a multi-key command.
        if !pending.isEmpty {
            handlePending(key)
            return
        }

        let n = count ?? 1

        if let target = motion(key, count: n) {
            move(to: target.location, keepColumn: target.keepColumn)
            count = nil
            return
        }

        switch key {
        case "i": beginChange(key); startInsert(at: caret)
        case "a": beginChange(key); startInsert(at: min(caret + 1, lineEnd(caret)))
        case "I": beginChange(key); startInsert(at: firstNonBlank(caret))
        case "A": beginChange(key); startInsert(at: lineEnd(caret))
        case "o":
            beginChange(key)
            let end = lineEnd(caret)
            let indent = currentIndent(caret)
            replace(NSRange(location: end, length: 0), with: "\n" + indent)
            startInsert(at: end + 1 + (indent as NSString).length)
        case "O":
            beginChange(key)
            let start = lineStart(caret)
            let indent = currentIndent(caret)
            replace(NSRange(location: start, length: 0), with: indent + "\n")
            startInsert(at: start + (indent as NSString).length)
        case "v", "V":
            if isVisual {
                let location = caret
                setMode(mode == .visual && key == "V" ? .visualLine : mode == .visualLine && key == "v" ? .visual : .normal)
                if mode == .normal { caret = location } else { updateVisualSelection(cursor: location) }
            } else {
                visualAnchor = caret
                mode = key == "v" ? .visual : .visualLine
                updateVisualSelection(cursor: caret)
                updateBlockCursor()
            }
        case "x" where !isVisual:
            beginChange(key)
            let end = min(caret + n, lineEnd(caret))
            if end > caret { deleteRange(NSRange(location: caret, length: end - caret), linewise: false) }
            clampToLine()
            finishChange()
        case "X" where !isVisual:
            beginChange(key)
            let start = max(lineStart(caret), caret - n)
            if start < caret { deleteRange(NSRange(location: start, length: caret - start), linewise: false) }
            finishChange()
        case "D" where !isVisual:
            beginChange(key)
            deleteRange(NSRange(location: caret, length: lineEnd(caret) - caret), linewise: false)
            clampToLine()
            finishChange()
        case "C" where !isVisual:
            beginChange(key)
            deleteRange(NSRange(location: caret, length: lineEnd(caret) - caret), linewise: false)
            startInsert(at: caret)
        case "s" where !isVisual:
            beginChange(key)
            let end = min(caret + n, lineEnd(caret))
            deleteRange(NSRange(location: caret, length: end - caret), linewise: false)
            startInsert(at: caret)
        case "S" where !isVisual:
            beginChange(key)
            changeLines(count: n)
        case "Y" where !isVisual:
            yankLines(count: n)
        case "p", "P":
            if isVisual {
                let range = visualRange()
                let saved = (register, registerLinewise)
                beginChange(key)
                deleteRange(range, linewise: mode == .visualLine)
                setMode(.normal)
                (register, registerLinewise) = saved
                put(before: true, count: 1)
            } else {
                beginChange(key)
                put(before: key == "P", count: n)
            }
            finishChange()
        case "u", "<Undo>":
            for _ in 0..<n { textView?.undoManager?.undo() }
            caret = min(caret, length)
            clampToLine()
        case "<C-r>":
            for _ in 0..<n { textView?.undoManager?.redo() }
            clampToLine()
        case "J" where !isVisual:
            beginChange(key)
            joinLines(count: max(1, n - 1))
            finishChange()
        case "~" where !isVisual:
            beginChange(key)
            let end = min(caret + n, lineEnd(caret))
            toggleCase(NSRange(location: caret, length: end - caret))
            caret = min(end, lastColumn(caret))
            finishChange()
        case ".":
            repeatLastChange(count: count)
        case ":":
            if isVisual {
                commandLine = "'<,'>"
            } else {
                commandLine = ""
            }
            mode = .command
        case "/", "?":
            commandLine = ""
            mode = .search(forward: key == "/")
        case "n", "N":
            if let last = lastSearch { search(last.pattern, forward: key == "n" ? last.forward : !last.forward) }
        case "*", "#":
            let word = wordUnderCursor()
            if !word.isEmpty {
                lastSearch = ("\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", key == "*")
                search(lastSearch!.pattern, forward: key == "*", regex: true)
            }
        case "<C-d>", "<C-u>":
            let lines = max(1, visibleLineCount() / 2)
            move(to: lineStart(from: caret, delta: key == "<C-d>" ? lines : -lines), keepColumn: true)
        case "d", "c", "y", ">", "<", "r":
            if isVisual, key != "r" {
                applyVisual(key)
            } else {
                if key != "y", recording == nil, !replaying {
                    recording = (count.map { String($0).map(String.init) } ?? []) + [key]
                }
                pending = key
                return
            }
        case "g", "f", "F", "t", "T", "z", "Z", "m", "'", "`", "\"":
            pending = key
            return
        default:
            break
        }
        count = nil
    }

    private func handlePending(_ key: String) {
        let op = pending
        let n = count ?? 1
        pending = ""

        switch op {
        case "g":
            if key == "g" {
                move(to: count.map { lineStart(from: 0, delta: $0 - 1) }.map(firstNonBlank) ?? firstNonBlank(0), keepColumn: false)
            } else if key == "_" {
                move(to: lastNonBlank(caret), keepColumn: false)
            }
            count = nil
            return
        case "r":
            if key.count == 1, mode == .normal {
                let end = min(caret + n, lineEnd(caret))
                if end - caret == n {
                    replace(NSRange(location: caret, length: n), with: String(repeating: key, count: n))
                    caret = end - 1
                }
                finishChange()
            }
            count = nil
            return
        case "f", "F", "t", "T":
            if let target = findInLine(op, key, count: n) { move(to: target, keepColumn: false) }
            count = nil
            return
        case "z":
            if key == "z" || key == "." { textView?.scrollRangeToVisible(NSRange(location: caret, length: 0)) }
            count = nil
            return
        case "Z":
            if key == "Z" { onCommand?("x") } else if key == "Q" { onCommand?("q!") }
            count = nil
            return
        case "m", "'", "`", "\"":
            count = nil  // Marks and named registers aren't supported; swallow the key.
            return
        default:
            break
        }

        // Operators: d c y > <, doubled (dd), followed by a motion, a text object (diw) or gg (dgg).
        guard let first = op.first, "dcy><".contains(first) else { return }
        let operatorKey = String(first)
        let suffix = op.dropFirst()
        if suffix == "i" || suffix == "a" {
            if let range = textObject(inner: suffix == "i", key) {
                applyOperator(operatorKey, range: range, linewise: false)
            } else {
                recording = nil
            }
        } else if suffix == "g" {
            if key == "g" {
                let start = 0
                let end = min(length, text.lineRange(for: NSRange(location: caret, length: 0)).upperBound)
                applyOperator(operatorKey, range: NSRange(location: start, length: end - start), linewise: true)
            }
        } else if key == operatorKey {
            applyLinewise(operatorKey, count: n)
        } else if key == "i" || key == "a" || key == "g" {
            pending = op + key
            return
        } else if let operatorMotion = operatorRange(key, count: n, operator: operatorKey) {
            applyOperator(operatorKey, range: operatorMotion.range, linewise: operatorMotion.linewise)
        } else {
            recording = nil
        }
        count = nil
    }

    // MARK: Motions

    private struct Target {
        let location: Int
        var keepColumn = false
        var inclusive = false
        var linewise = false
    }

    private func motion(_ key: String, count n: Int) -> Target? {
        let location = caret
        switch key {
        case "h", "<BS>", "<Left>":
            return Target(location: max(lineStart(location), location - n))
        case "l", " ", "<Right>":
            let limit = mode == .normal ? lastColumn(location) : lineEnd(location)
            return Target(location: min(limit, location + n))
        case "j", "<Down>", "<CR>", "+":
            let start = lineStart(from: location, delta: n)
            if key == "<CR>" || key == "+" { return Target(location: firstNonBlank(start), linewise: true) }
            return Target(location: start, keepColumn: true, linewise: true)
        case "k", "<Up>", "-":
            let start = lineStart(from: location, delta: -n)
            if key == "-" { return Target(location: firstNonBlank(start), linewise: true) }
            return Target(location: start, keepColumn: true, linewise: true)
        case "0", "<Home>":
            return Target(location: lineStart(location))
        case "^", "_":
            return Target(location: firstNonBlank(location))
        case "$", "<End>":
            let end = lineStart(from: location, delta: n - 1)
            return Target(location: mode == .normal ? lastColumn(end) : lineEnd(end), inclusive: true)
        case "w", "W":
            var position = location
            for _ in 0..<n { position = nextWordStart(position, big: key == "W") }
            return Target(location: position)
        case "b", "B":
            var position = location
            for _ in 0..<n { position = previousWordStart(position, big: key == "B") }
            return Target(location: position)
        case "e", "E":
            var position = location
            for _ in 0..<n { position = wordEnd(position, big: key == "E") }
            return Target(location: position, inclusive: true)
        case "G":
            let target = count.map { lineStart(from: 0, delta: $0 - 1) } ?? lineStart(max(0, length - 1))
            return Target(location: firstNonBlank(target), linewise: true)
        case "}":
            var position = location
            for _ in 0..<n { position = paragraph(from: position, forward: true) }
            return Target(location: position)
        case "{":
            var position = location
            for _ in 0..<n { position = paragraph(from: position, forward: false) }
            return Target(location: position)
        case "%":
            return matchingBracket(location).map { Target(location: $0, inclusive: true) }
        case "H":
            return Target(location: firstNonBlank(visibleRangeStart()), linewise: true)
        case "L":
            return Target(location: firstNonBlank(lineStart(max(0, visibleRangeEnd() - 1))), linewise: true)
        default:
            return nil
        }
    }

    private func move(to location: Int, keepColumn: Bool) {
        var target = location
        if keepColumn {
            let column = desiredColumn ?? column(caret)
            desiredColumn = column
            target = min(lineStart(location) + column, mode == .normal ? lastColumn(location) : lineEnd(location))
        } else {
            desiredColumn = nil
        }
        if mode == .visual || mode == .visualLine {
            updateVisualSelection(cursor: target)
        } else {
            caret = target
        }
    }

    private func nextWordStart(_ location: Int, big: Bool) -> Int {
        guard let c = char(location) else { return location }
        var position = location
        let start = big ? (isSpace(c) ? 0 : 1) : charClass(c)
        if start != 0 {
            while let next = char(position), (big ? (isSpace(next) ? 0 : 1) : charClass(next)) == start {
                position += 1
            }
        }
        while let next = char(position), isSpace(next) {
            if isNewline(next), isNewline(char(position + 1)) { return position + 1 }  // stop at empty lines
            position += 1
        }
        return min(position, max(0, length - (mode == .normal ? 1 : 0)))
    }

    private func previousWordStart(_ location: Int, big: Bool) -> Int {
        var position = location - 1
        while position > 0, let c = char(position), isSpace(c) { position -= 1 }
        guard let c = char(position) else { return 0 }
        let kind = big ? 1 : charClass(c)
        while position > 0, let previous = char(position - 1), (big ? (isSpace(previous) ? 0 : 1) : charClass(previous)) == kind {
            position -= 1
        }
        return max(0, position)
    }

    private func wordEnd(_ location: Int, big: Bool) -> Int {
        var position = location + 1
        while let c = char(position), isSpace(c) { position += 1 }
        guard let c = char(position) else { return max(0, length - 1) }
        let kind = big ? 1 : charClass(c)
        while let next = char(position + 1), (big ? (isSpace(next) ? 0 : 1) : charClass(next)) == kind { position += 1 }
        return position
    }

    private func paragraph(from location: Int, forward: Bool) -> Int {
        var position = lineStart(location)
        // Skip blank lines, then find the next blank line.
        func isBlank(_ start: Int) -> Bool { lineEnd(start) == start }
        var skipping = true
        while true {
            let next = lineStart(from: position, delta: forward ? 1 : -1)
            if next == position { return forward ? length : 0 }
            position = next
            if isBlank(position) {
                if !skipping { return position }
            } else {
                skipping = false
            }
        }
    }

    private func matchingBracket(_ location: Int) -> Int? {
        let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true), 41: (40, false), 93: (91, false), 125: (123, false)]
        var position = location
        let end = lineEnd(location)
        while position < end, let c = char(position), pairs[c] == nil { position += 1 }
        guard let open = char(position), let (close, forward) = pairs[open] else { return nil }
        var depth = 0
        var index = position
        while let c = char(index) {
            if c == open { depth += 1 } else if c == close { depth -= 1 }
            if depth == 0 { return index }
            index += forward ? 1 : -1
            if index < 0 { break }
        }
        return nil
    }

    private func findInLine(_ op: String, _ key: String, count n: Int) -> Int? {
        guard let target = (key as NSString).length == 1 ? (key as NSString).character(at: 0) : nil else { return nil }
        let forward = op == "f" || op == "t"
        var position = caret
        var found = 0
        let start = lineStart(caret), end = lineEnd(caret)
        while true {
            position += forward ? 1 : -1
            if position < start || position >= end { return nil }
            if char(position) == target {
                found += 1
                if found == n { break }
            }
        }
        if op == "t" { return position - 1 }
        if op == "T" { return position + 1 }
        return position
    }

    private func lastNonBlank(_ location: Int) -> Int {
        var position = lineEnd(location) - 1
        while position > lineStart(location), let c = char(position), c == 32 || c == 9 { position -= 1 }
        return max(lineStart(location), position)
    }

    private func currentIndent(_ location: Int) -> String {
        text.substring(with: NSRange(location: lineStart(location), length: firstNonBlank(location) - lineStart(location)))
    }

    private func wordUnderCursor() -> String {
        guard let range = textObject(inner: true, "w"), range.length > 0 else { return "" }
        return text.substring(with: range)
    }

    // MARK: Operators

    private func operatorRange(_ key: String, count n: Int, operator op: String) -> (range: NSRange, linewise: Bool)? {
        // cw behaves like ce (doesn't eat trailing space).
        let motionKey = key == "w" && op == "c" ? "e" : key == "W" && op == "c" ? "E" : key
        guard let target = motion(motionKey, count: n) else {
            return nil
        }
        let from = caret
        if target.linewise {
            let start = lineStart(min(from, target.location))
            var end = text.lineRange(for: NSRange(location: max(from, target.location), length: 0)).upperBound
            if end == length, start > 0, lineEnd(max(from, target.location)) == length {
                // Deleting the last line also removes the newline before it.
                return (NSRange(location: start - 1, length: end - start + 1), true)
            }
            end = min(end, length)
            return (NSRange(location: start, length: end - start), true)
        }
        var lower = min(from, target.location), upper = max(from, target.location)
        if target.inclusive || motionKey == "e" || motionKey == "E" { upper = min(length, upper + 1) }
        if key == "w", op != "c", upper > lineEnd(from), lineEnd(from) > from {
            upper = lineEnd(from)  // dw at end of line doesn't join lines
        }
        lower = max(0, lower)
        return (NSRange(location: lower, length: upper - lower), false)
    }

    private func applyOperator(_ op: String, range: NSRange, linewise: Bool) {
        switch op {
        case "d":
            deleteRange(range, linewise: linewise)
            if linewise { caret = firstNonBlank(min(range.location, max(0, length - 1))) }
            clampToLine()
            finishChange()
        case "c":
            if linewise {
                let indent = currentIndent(range.location)
                yank(range, linewise: true)
                var lineRange = range
                if text.substring(with: range).hasSuffix("\n") { lineRange.length -= 1 }
                replace(lineRange, with: indent)
                startInsert(at: lineRange.location + (indent as NSString).length)
            } else {
                deleteRange(range, linewise: false)
                startInsert(at: range.location)
            }
        case "y":
            yank(range, linewise: linewise)
            caret = linewise ? caret : range.location
            let lines = register.components(separatedBy: "\n").count - 1
            message = linewise && lines > 1 ? "\(lines) lines yanked" : nil
            recording = nil
        case ">", "<":
            indent(range, outdent: op == "<")
            finishChange()
        default:
            break
        }
    }

    private func applyLinewise(_ op: String, count n: Int) {
        let start = lineStart(caret)
        let lastLineStart = lineStart(from: caret, delta: n - 1)
        var end = text.lineRange(for: NSRange(location: lastLineStart, length: 0)).upperBound
        var location = start
        if op == "d", end == length, start > 0, lineEnd(lastLineStart) == length {
            location = start - 1  // last line: take the preceding newline instead
        }
        end = min(end, length)
        if op == "c" {
            changeLines(count: n)
            return
        }
        applyOperator(op, range: NSRange(location: location, length: end - location), linewise: true)
    }

    private func applyVisual(_ op: String) {
        let range = visualRange()
        let linewise = mode == .visualLine
        let start = range.location
        setMode(.normal)
        caret = start
        recording = nil
        applyOperator(op, range: range, linewise: linewise)
        if op == "y" { caret = start }
    }

    private func visualRange() -> NSRange {
        guard let selection = textView?.selectedRange else { return NSRange() }
        return selection
    }

    private func updateVisualSelection(cursor: Int) {
        guard let textView else { return }
        var lower = min(visualAnchor, cursor), upper = max(visualAnchor, cursor)
        if mode == .visualLine {
            lower = lineStart(lower)
            upper = min(length, text.lineRange(for: NSRange(location: upper, length: 0)).upperBound)
        } else {
            upper = min(length, upper + 1)
        }
        textView.selectedRange = NSRange(location: lower, length: upper - lower)
        visualCursor = cursor
    }

    private var visualCursor = 0

    private func deleteRange(_ range: NSRange, linewise: Bool) {
        guard range.length > 0 else { return }
        yank(range, linewise: linewise)
        replace(range, with: "")
        caret = range.location
    }

    private func changeLines(count n: Int) {
        let start = lineStart(caret)
        let lastLineStart = lineStart(from: caret, delta: n - 1)
        let end = lineEnd(lastLineStart)
        let indent = currentIndent(start)
        yank(NSRange(location: start, length: end - start), linewise: true)
        replace(NSRange(location: start, length: end - start), with: indent)
        startInsert(at: start + (indent as NSString).length)
    }

    private func yankLines(count n: Int) {
        let start = lineStart(caret)
        let lastLineStart = lineStart(from: caret, delta: n - 1)
        let end = min(length, text.lineRange(for: NSRange(location: lastLineStart, length: 0)).upperBound)
        yank(NSRange(location: start, length: end - start), linewise: true)
    }

    private func put(before: Bool, count n: Int) {
        let content = register
        let linewise = registerLinewise
        guard !content.isEmpty else { return }
        let repeated = String(repeating: content, count: n)
        if linewise {
            var block = repeated
            if !block.hasSuffix("\n") { block += "\n" }
            let location: Int
            if before {
                location = lineStart(caret)
            } else {
                let upper = text.lineRange(for: NSRange(location: caret, length: 0)).upperBound
                if upper == length, !text.hasSuffix("\n") {
                    replace(NSRange(location: length, length: 0), with: "\n" + String(block.dropLast()))
                    caret = firstNonBlank(lineStart(from: caret, delta: 1))
                    return
                }
                location = upper
            }
            replace(NSRange(location: location, length: 0), with: block)
            caret = firstNonBlank(location)
        } else {
            let location = before || length == 0 || isNewline(char(caret)) ? caret : caret + 1
            replace(NSRange(location: location, length: 0), with: repeated)
            caret = location + (repeated as NSString).length - 1
        }
    }

    private func joinLines(count n: Int) {
        for _ in 0..<n {
            let end = lineEnd(caret)
            guard end < length else { return }
            var next = end + 1
            while let c = char(next), c == 32 || c == 9 { next += 1 }
            let separator = isNewline(char(next)) || char(end - 1) == 32 ? "" : " "
            replace(NSRange(location: end, length: next - end), with: separator)
            caret = end
        }
    }

    private func toggleCase(_ range: NSRange) {
        guard range.length > 0 else { return }
        let original = text.substring(with: range)
        let toggled = String(original.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        replace(range, with: toggled)
    }

    private func indent(_ range: NSRange, outdent: Bool) {
        let start = lineStart(range.location)
        let end = lineEnd(max(range.location, range.upperBound - 1))
        let block = text.substring(with: NSRange(location: start, length: end - start))
        let lines = block.components(separatedBy: "\n").map { line -> String in
            if outdent {
                var trimmed = Substring(line)
                var removed = 0
                while removed < 4, trimmed.first == " " { trimmed = trimmed.dropFirst(); removed += 1 }
                if removed == 0, trimmed.first == "\t" { trimmed = trimmed.dropFirst() }
                return String(trimmed)
            }
            return line.isEmpty ? line : "    " + line
        }
        replace(NSRange(location: start, length: end - start), with: lines.joined(separator: "\n"))
        caret = firstNonBlank(start)
    }

    // MARK: Text objects

    private func textObject(inner: Bool, _ key: String) -> NSRange? {
        let location = caret
        switch key {
        case "w", "W":
            guard let c = char(location), !isNewline(c) else { return nil }
            let kind = key == "W" ? (isSpace(c) ? 0 : 1) : charClass(c)
            func same(_ position: Int) -> Bool {
                guard let d = char(position), !isNewline(d) else { return false }
                return (key == "W" ? (isSpace(d) ? 0 : 1) : charClass(d)) == kind
            }
            var lower = location, upper = location + 1
            while lower > lineStart(location), same(lower - 1) { lower -= 1 }
            while upper < lineEnd(location), same(upper) { upper += 1 }
            if !inner {
                while upper < lineEnd(location), let d = char(upper), d == 32 || d == 9 { upper += 1 }
            }
            return NSRange(location: lower, length: upper - lower)
        case "\"", "'", "`":
            let quote = (key as NSString).character(at: 0)
            let start = lineStart(location), end = lineEnd(location)
            var quotes: [Int] = []
            for position in start..<end where char(position) == quote { quotes.append(position) }
            var pair: (Int, Int)?
            for i in stride(from: 0, to: quotes.count - 1, by: 2) where quotes[i] <= location && location <= quotes[i + 1] {
                pair = (quotes[i], quotes[i + 1])
            }
            if pair == nil, let next = quotes.firstIndex(where: { $0 > location }), next + 1 < quotes.count {
                pair = (quotes[next], quotes[next + 1])
            }
            guard let (open, close) = pair else { return nil }
            return inner ? NSRange(location: open + 1, length: close - open - 1) : NSRange(location: open, length: close - open + 1)
        case "(", ")", "b", "[", "]", "{", "}", "B", "<", ">":
            let pairs: [String: (unichar, unichar)] = [
                "(": (40, 41), ")": (40, 41), "b": (40, 41), "[": (91, 93), "]": (91, 93),
                "{": (123, 125), "}": (123, 125), "B": (123, 125), "<": (60, 62), ">": (60, 62),
            ]
            guard let (open, close) = pairs[key] else { return nil }
            var depth = 0
            var lower = location
            if char(location) == close { lower -= 1 }
            while lower >= 0 {
                if char(lower) == close { depth += 1 } else if char(lower) == open {
                    if depth == 0 { break }
                    depth -= 1
                }
                lower -= 1
            }
            guard lower >= 0 else { return nil }
            depth = 0
            var upper = lower + 1
            while upper < length {
                if char(upper) == open { depth += 1 } else if char(upper) == close {
                    if depth == 0 { break }
                    depth -= 1
                }
                upper += 1
            }
            guard upper < length else { return nil }
            return inner ? NSRange(location: lower + 1, length: upper - lower - 1) : NSRange(location: lower, length: upper - lower + 1)
        default:
            return nil
        }
    }

    // MARK: Repeat

    private func repeatLastChange(count newCount: Int?) {
        guard !lastChange.isEmpty else { return }
        replaying = true
        var keys = lastChange
        if let newCount {
            keys = keys.drop(while: { Int($0) != nil }).map { $0 }
            keys = String(newCount).map(String.init) + keys
        }
        count = nil
        for key in keys {
            if key.hasPrefix("i:") {
                replace(NSRange(location: caret, length: 0), with: String(key.dropFirst(2)))
                caret += (String(key.dropFirst(2)) as NSString).length
            } else if key == "<BS>", mode == .insert {
                if caret > 0 {
                    replace(NSRange(location: caret - 1, length: 1), with: "")
                    caret -= 1
                }
            } else {
                handle(key)
            }
        }
        if mode == .insert { handle("<Esc>") }
        replaying = false
    }

    // MARK: Search

    private func search(_ pattern: String, forward: Bool, regex: Bool = false) {
        let options: NSString.CompareOptions = pattern == pattern.lowercased() ? [.caseInsensitive] : []
        var matches: [NSRange] = []
        if let expression = try? NSRegularExpression(pattern: pattern, options: options.contains(.caseInsensitive) ? [.caseInsensitive] : []) {
            matches = expression.matches(in: text as String, range: NSRange(location: 0, length: length)).map(\.range)
        }
        if matches.isEmpty && !regex {
            var searchRange = NSRange(location: 0, length: length)
            while true {
                let found = text.range(of: pattern, options: options, range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                matches.append(found)
                searchRange = NSRange(location: found.upperBound, length: length - found.upperBound)
            }
        }
        highlightMatches(matches)
        guard !matches.isEmpty else {
            message = "Pattern not found: \(pattern)"
            return
        }
        let location = caret
        let target = forward
            ? matches.first(where: { $0.location > location }) ?? matches.first!
            : matches.last(where: { $0.location < location }) ?? matches.last!
        if forward ? target.location <= location : target.location >= location {
            message = forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM"
        }
        caret = target.location
        textView?.scrollRangeToVisible(target)
    }

    private func highlightMatches(_ matches: [NSRange]) {
        guard let textView else { return }
        var ranges = textView.highlightedRanges.filter { !$0.id.hasPrefix("vim.search") }
        ranges += matches.prefix(500).enumerated().map { index, range in
            HighlightedRange(id: "vim.search.\(index)", range: range, color: Gruvbox.yellow.withAlphaComponent(0.35), cornerRadius: 2)
        }
        textView.highlightedRanges = ranges
    }

    func clearSearchHighlights() {
        highlightMatches([])
    }

    // MARK: Command line

    private func handleCommandLine(_ key: String) {
        switch key {
        case "<Esc>":
            commandLine = ""
            setMode(.normal)
        case "<BS>":
            if commandLine.isEmpty {
                setMode(.normal)
            } else {
                commandLine.removeLast()
            }
        case "<CR>":
            let line = commandLine
            let wasSearch = mode
            commandLine = ""
            setMode(.normal)
            if case .search(let forward) = wasSearch {
                if line.isEmpty, let last = lastSearch {
                    search(last.pattern, forward: forward)
                } else if !line.isEmpty {
                    lastSearch = (line, forward)
                    search(line, forward: forward)
                }
            } else if !line.isEmpty {
                commandHistory.append(line)
                executeCommand(line)
            }
        case "<Tab>":
            break
        default:
            if !key.hasPrefix("<") { commandLine += key }
        }
    }

    private func executeCommand(_ line: String) {
        var command = line.trimmingCharacters(in: .whitespaces)
        var range: (Int, Int)?
        if command.hasPrefix("'<,'>") {
            command.removeFirst(5)
            let selection = visualRange()
            range = (selection.location, selection.upperBound)
        } else if command.hasPrefix("%") {
            command.removeFirst()
            range = (0, length)
        }

        if let number = Int(command) {
            move(to: firstNonBlank(lineStart(from: 0, delta: max(0, number - 1))), keepColumn: false)
            return
        }
        if command.hasPrefix("s/") || command.hasPrefix("s#") {
            substitute(command, in: range ?? (lineStart(caret), lineEnd(caret)))
            return
        }
        switch command {
        case "noh", "nohlsearch":
            clearSearchHighlights()
        case "$":
            move(to: firstNonBlank(lineStart(max(0, length - 1))), keepColumn: false)
        default:
            onCommand?(command)
        }
    }

    private func substitute(_ command: String, in range: (Int, Int)) {
        let separator = command[command.index(after: command.startIndex)]
        let parts = command.dropFirst(2).split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else {
            message = "E486: usage :s/pattern/replacement/[g]"
            return
        }
        let flags = parts.count > 2 ? parts[2] : ""
        let caseInsensitive = flags.contains("i")
        guard let expression = try? NSRegularExpression(pattern: parts[0], options: caseInsensitive ? [.caseInsensitive] : []) else {
            message = "E486: invalid pattern"
            return
        }
        let start = lineStart(range.0), end = lineEnd(max(range.0, range.1 - 1))
        let block = text.substring(with: NSRange(location: start, length: end - start))
        let template = parts[1].replacingOccurrences(of: "\\&", with: "\u{0}").replacingOccurrences(of: "&", with: "$0").replacingOccurrences(of: "\u{0}", with: "&")
        var replaced = 0
        let lines = block.components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            let lineRange = NSRange(location: 0, length: ns.length)
            if flags.contains("g") {
                replaced += expression.numberOfMatches(in: line, range: lineRange)
                return expression.stringByReplacingMatches(in: line, range: lineRange, withTemplate: template)
            }
            guard let first = expression.firstMatch(in: line, range: lineRange) else { return line }
            replaced += 1
            let replacement = expression.replacementString(for: first, in: line, offset: 0, template: template)
            return ns.replacingCharacters(in: first.range, with: replacement)
        }
        guard replaced > 0 else {
            message = "E486: Pattern not found: \(parts[0])"
            return
        }
        replace(NSRange(location: start, length: end - start), with: lines.joined(separator: "\n"))
        caret = firstNonBlank(start)
        message = "\(replaced) substitution\(replaced == 1 ? "" : "s")"
    }

    func showMessage(_ text: String) {
        message = text
        onStateChange?()
    }

    // MARK: Viewport

    private func visibleLineCount() -> Int {
        guard let textView else { return 20 }
        let lineHeight = textView.theme.font.lineHeight * textView.lineHeightMultiplier
        return Int(textView.bounds.height / max(1, lineHeight))
    }

    private func visibleRangeStart() -> Int {
        guard let textView else { return 0 }
        let lineHeight = textView.theme.font.lineHeight * textView.lineHeightMultiplier
        let firstLine = Int(textView.contentOffset.y / max(1, lineHeight))
        return lineStart(from: 0, delta: firstLine)
    }

    private func visibleRangeEnd() -> Int {
        lineStart(from: visibleRangeStart(), delta: visibleLineCount() - 1)
    }

    /// 1-based line and column for the status line.
    var position: (line: Int, column: Int) {
        let location = caret
        let prefix = text.substring(to: min(location, length))
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return (line, column(location) + 1)
    }
}
