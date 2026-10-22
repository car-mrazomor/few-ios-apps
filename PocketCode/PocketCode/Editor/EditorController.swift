import Observation
import Runestone
import TreeSitterBashRunestone
import TreeSitterCSSRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPythonRunestone
import TreeSitterTOMLRunestone
import TreeSitterYAMLRunestone
import UIKit

/// One open file: its text view, vim state and save state. Kept alive while the buffer is open so undo history survives.
@MainActor @Observable
final class EditorController: NSObject, OpenDocument {
    let url: URL
    private(set) var isModified = false
    private(set) var modeLabel = "NORMAL"
    private(set) var commandLine: String?
    private(set) var message: String?
    private(set) var pendingKeys = ""
    private(set) var line = 1
    private(set) var column = 1
    private(set) var lineCount = 1

    var name: String { url.lastPathComponent }
    var fileType: String { Self.fileType(for: url) }

    @ObservationIgnored let textView = VimTextView()
    @ObservationIgnored private var vim: VimEngine!
    @ObservationIgnored private var vimEnabled: Bool
    /// Asks the app to run a shell command (Run button, :run).
    @ObservationIgnored var runCommand: ((String) -> Void)?
    /// Asks the app to open another file (:e) or close this buffer (:q).
    @ObservationIgnored var openFile: ((URL) -> Void)?
    @ObservationIgnored var close: (() -> Void)?

    init(url: URL, fontSize: CGFloat, vimEnabled: Bool) {
        self.url = url
        self.vimEnabled = vimEnabled
        super.init()
        configureTextView(fontSize: fontSize)
        vim = VimEngine(textView: textView)
        vim.onStateChange = { [weak self] in self?.refreshStatus() }
        vim.onCommand = { [weak self] in self?.execute($0) }
        load()
        if !vimEnabled { vim.enterInsertFromTap() }
        refreshStatus()
    }

    // MARK: Setup

    private func configureTextView(fontSize: CGFloat) {
        let theme = GruvboxEditorTheme(fontSize: fontSize)
        textView.theme = theme
        textView.backgroundColor = Gruvbox.bg0
        textView.editorDelegate = self
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line  // cursorline
        textView.lineHeightMultiplier = 1.15
        textView.isLineWrappingEnabled = false
        textView.indentStrategy = .space(length: 4)
        textView.characterPairs = []
        textView.gutterLeadingPadding = 6
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 8)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardAppearance = .dark
        textView.alwaysBounceVertical = true
        textView.onKey = { [weak self] in self?.key($0) }
        textView.onSave = { [weak self] in self?.save() }
        textView.onRun = { [weak self] in self?.run() }
        textView.inputAccessoryView = EditorKeyBar(
            onKey: { [weak self] in self?.key($0) },
            onPaste: { [weak self] in self?.paste() },
            onHide: { [weak self] in _ = self?.textView.resignFirstResponder() }
        )
    }

    private func load() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let theme = textView.theme
        if let language = Self.language(for: url) {
            textView.setState(TextViewState(text: text, theme: theme, language: language))
        } else {
            textView.setState(TextViewState(text: text, theme: theme))
        }
        textView.selectedRange = NSRange(location: 0, length: 0)
        isModified = false
        lineCount = max(1, text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
    }

    func setFontSize(_ size: Double) {
        textView.theme = GruvboxEditorTheme(fontSize: size)
    }

    func setVimEnabled(_ enabled: Bool) {
        vimEnabled = enabled
        if enabled {
            vim.handle("<Esc>")
        } else {
            vim.enterInsertFromTap()
        }
        refreshStatus()
    }

    // MARK: Keys

    /// Keys from the key bar and hardware shortcuts.
    func key(_ key: String) {
        if !vimEnabled || vim.mode == .insert {
            switch key {
            case "<Esc>": if vimEnabled { vim.handle(key) }
            case "<Left>": moveCaret(by: -1)
            case "<Right>": moveCaret(by: 1)
            case "<Up>", "<Down>": moveLine(up: key == "<Up>")
            case "<Undo>": textView.undoManager?.undo()
            case "<C-r>": textView.undoManager?.redo()
            case "<Tab>": insert("    ")
            case "<C-d>", "<C-u>": break
            default: insert(key)
            }
        } else {
            vim.handle(key)
        }
        refreshStatus()
    }

    private func insert(_ text: String) {
        let range = textView.selectedRange
        textView.applyEdit(range, with: text)
        textView.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        vim.noteInserted(text, deleted: false)
    }

    private func moveCaret(by delta: Int) {
        let length = (textView.text as NSString).length
        let location = max(0, min(length, textView.selectedRange.location + delta))
        textView.selectedRange = NSRange(location: location, length: 0)
    }

    private func moveLine(up: Bool) {
        // Reuse vim's line motion (keeps the column) by briefly leaving insert mode semantics aside.
        let text = textView.text as NSString
        let location = textView.selectedRange.location
        let current = text.lineRange(for: NSRange(location: location, length: 0))
        let column = location - current.location
        let target: NSRange
        if up {
            guard current.location > 0 else { return }
            target = text.lineRange(for: NSRange(location: current.location - 1, length: 0))
        } else {
            guard current.upperBound < text.length else { return }
            target = text.lineRange(for: NSRange(location: current.upperBound, length: 0))
        }
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: target)
        textView.selectedRange = NSRange(location: min(target.location + column, end), length: 0)
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if vimEnabled, vim.mode != .insert {
            vim.enterInsertFromTap()
            insert(text)
            vim.handle("<Esc>")
        } else {
            insert(text)
        }
        refreshStatus()
    }

    // MARK: Commands

    func save() {
        do {
            try textView.text.write(to: url, atomically: true, encoding: .utf8)
            isModified = false
            let lines = textView.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            vim.showMessage("\"\(name)\" \(lines)L written")
        } catch {
            vim.showMessage("E212: Can't open file for writing: \(error.localizedDescription)")
        }
    }

    func run() {
        save()
        runCommand?("run \(shellPath(url))")
    }

    private func execute(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        switch name {
        case "w", "write":
            save()
        case "q", "quit", "close", "bd":
            if isModified {
                vim.showMessage("E37: No write since last change (add ! to override)")
            } else {
                close?()
            }
        case "q!", "quit!", "bd!":
            close?()
        case "wq", "x", "xit", "wq!", "x!":
            save()
            if !isModified { close?() }
        case "e", "edit":
            guard let argument else { return load() }
            let target = argument.hasPrefix("/") ? URL(fileURLWithPath: argument)
                : url.deletingLastPathComponent().appending(path: argument)
            openFile?(target)
        case "e!":
            load()
        case "run", "r", "make", "!python", "!python3":
            run()
        case "set", "se":
            setOption(argument ?? "")
        case "help", "h":
            vim.showMessage("Normal: hjkl w b e 0 $ gg G f t % { } · d c y > < + motion · dd cc yy p u . · v V · / n N * · :w :q :wq :e :run :%s/a/b/g")
        default:
            vim.showMessage("E492: Not an editor command: \(command)")
        }
    }

    private func setOption(_ option: String) {
        switch option {
        case "wrap": textView.isLineWrappingEnabled = true
        case "nowrap": textView.isLineWrappingEnabled = false
        case "nu", "number": textView.showLineNumbers = true
        case "nonu", "nonumber": textView.showLineNumbers = false
        case "list": textView.showTabs = true; textView.showSpaces = true
        case "nolist": textView.showTabs = false; textView.showSpaces = false
        default: vim.showMessage("E518: Unknown option: \(option)")
        }
    }

    // MARK: Status

    private func refreshStatus() {
        guard vim != nil else { return }
        modeLabel = vimEnabled ? vim.mode.label : "EDIT"
        switch vim.mode {
        case .command: commandLine = ":" + vim.commandLine
        case .search(let forward): commandLine = (forward ? "/" : "?") + vim.commandLine
        default: commandLine = nil
        }
        message = vim.message
        pendingKeys = vim.pendingKeys
        let position = vim.position
        line = position.line
        column = position.column
    }

    // MARK: Languages

    static func language(for url: URL) -> TreeSitterLanguage? {
        switch url.pathExtension.lowercased() {
        case "py", "pyw", "pyi": .python
        case "json", "ipynb": .json
        case "md", "markdown": .markdown
        case "sh", "bash", "zsh": .bash
        case "yml", "yaml": .yaml
        case "js", "mjs", "cjs", "jsx": .javaScript
        case "html", "htm": .html
        case "css": .css
        case "toml": .toml
        default: nil
        }
    }

    static func fileType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "py", "pyw", "pyi": "python"
        case "json", "ipynb": "json"
        case "md", "markdown": "markdown"
        case "sh", "bash", "zsh": "sh"
        case "yml", "yaml": "yaml"
        case "js", "mjs", "cjs", "jsx": "javascript"
        case "": "text"
        case let other: other
        }
    }

    /// Quotes for the shell only when needed.
    nonisolated static func quoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

// MARK: - TextViewDelegate

extension EditorController: @preconcurrency TextViewDelegate {
    func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if self.textView.isApplyingEdit { return true }
        guard vimEnabled, vim.mode != .insert else {
            vim.noteInserted(text, deleted: text.isEmpty)
            return true
        }
        // Normal/visual/command mode: the keyboard sends vim commands instead of text.
        if text.isEmpty {
            vim.handle("<BS>")
        } else {
            for character in text {
                switch character {
                case "\n", "\r": vim.handle("<CR>")
                case "\t": vim.handle("<Tab>")
                default: vim.handle(String(character))
                }
            }
        }
        refreshStatus()
        return false
    }

    func textViewDidChange(_ textView: TextView) {
        isModified = true
        lineCount = max(1, textView.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        refreshStatus()
    }

    func textViewDidChangeSelection(_ textView: TextView) {
        if vimEnabled, vim.mode == .normal { vim.updateBlockCursor() }
        refreshStatus()
    }
}
