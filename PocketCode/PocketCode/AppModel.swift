import Foundation
import Observation
import Security

/// An open file tab: a text file (EditorController) or a notebook (NotebookController).
@MainActor
protocol OpenDocument: AnyObject {
    var url: URL { get }
    var name: String { get }
    var isModified: Bool { get }
    func save()
    func setFontSize(_ size: Double)
    func setVimEnabled(_ enabled: Bool)
}

@MainActor @Observable
final class AppModel {
    enum Tab: Hashable { case files, editor, terminal }

    var tab: Tab = .files
    var showingSettings = false
    private(set) var documents: [any OpenDocument] = []
    var currentDocumentURL: URL?
    /// Bumped whenever files may have changed (shell commands, saves), so the browser reloads.
    private(set) var filesRevision = 0

    var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 14 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            documents.forEach { $0.setFontSize(fontSize) }
            terminal.view.apply(theme: .gruvbox, fontSize: fontSize - 1)
        }
    }

    var vimEnabled: Bool = UserDefaults.standard.object(forKey: "vimEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(vimEnabled, forKey: "vimEnabled")
            documents.forEach { $0.setVimEnabled(vimEnabled) }
        }
    }

    let workspace = URL.documentsDirectory.resolvingSymlinksInPath()
    let terminal: TerminalSession

    init() {
        let size = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 14
        terminal = TerminalSession(fontSize: size - 1)
        terminal.onOpenFile = { [weak self] in self?.open($0) }
        terminal.onFilesChanged = { [weak self] in self?.filesRevision += 1 }
        seedWorkspaceIfEmpty()
        terminal.start()
        Task { await sendGitCredentials() }
    }

    var currentDocument: (any OpenDocument)? {
        documents.first { $0.url == currentDocumentURL } ?? documents.last
    }

    // MARK: Files

    func open(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        if !documents.contains(where: { $0.url == url }) {
            if url.pathExtension.lowercased() == "ipynb" {
                let notebook = NotebookController(url: url, fontSize: fontSize, vimEnabled: vimEnabled)
                notebook.onFilesChanged = { [weak self] in self?.filesRevision += 1 }
                documents.append(notebook)
            } else {
                let editor = EditorController(url: url, fontSize: fontSize, vimEnabled: vimEnabled)
                editor.runCommand = { [weak self] command in
                    self?.tab = .terminal
                    self?.terminal.run(command)
                }
                editor.openFile = { [weak self] in self?.open($0) }
                editor.close = { [weak self, weak editor] in
                    if let editor { self?.close(editor) }
                }
                documents.append(editor)
            }
        }
        currentDocumentURL = url
        tab = .editor
    }

    func close(_ document: any OpenDocument) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        if document.isModified { document.save() }
        documents.remove(at: index)
        if currentDocumentURL == document.url {
            currentDocumentURL = documents.isEmpty ? nil : documents[max(0, index - 1)].url
        }
        if documents.isEmpty { tab = .files }
    }

    /// Creates a new notebook in `folder` and opens it.
    func newNotebook(in folder: URL) {
        var index = 1
        var url = folder.appending(path: "Untitled.ipynb")
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = folder.appending(path: "Untitled \(index).ipynb")
        }
        try? NotebookController.emptyNotebook().write(to: url, atomically: true, encoding: .utf8)
        filesRevision += 1
        open(url)
    }

    func runInTerminal(_ command: String) {
        tab = .terminal
        terminal.run(command)
    }

    func filesChanged() {
        filesRevision += 1
    }

    private func seedWorkspaceIfEmpty() {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []
        guard contents.filter({ !$0.hasPrefix(".") }).isEmpty else { return }
        let hello = """
        # Welcome to PocketCode 👋
        # Run this file with the ▶ button (or :run). In the terminal, try: help, pip install rich, git clone <url>

        name = input("What's your name? ")
        print(f"Hello, {name}! Python is running on your iPhone.")

        squares = [n * n for n in range(1, 11)]
        print("Squares:", squares)

        """
        try? hello.write(to: workspace.appending(path: "hello.py"), atomically: true, encoding: .utf8)
    }

    // MARK: Git settings

    var gitName: String {
        get { GitConfig.value("user", "name") ?? "" }
        set { GitConfig.set("user", "name", newValue) }
    }

    var gitEmail: String {
        get { GitConfig.value("user", "email") ?? "" }
        set { GitConfig.set("user", "email", newValue) }
    }

    var gitUsername: String {
        get { UserDefaults.standard.string(forKey: "gitUsername") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "gitUsername")
            Task { await sendGitCredentials() }
        }
    }

    var gitToken: String { Keychain.get("gitToken") ?? "" }

    /// Stores the token in the Keychain and hands it to the git command. Returns false if the Keychain refused it.
    func saveGitToken(_ token: String) -> Bool {
        let saved = Keychain.set(token, for: "gitToken")
        Task { await sendGitCredentials() }
        return saved
    }

    private func sendGitCredentials() async {
        _ = await PythonEngine.shared.call("set_git_credentials", "\(gitUsername)\n\(gitToken)")
    }
}

/// A path for typing into the shell: "~/..." inside the workspace, quoted where needed.
func shellPath(_ url: URL) -> String {
    let workspace = URL.documentsDirectory.resolvingSymlinksInPath().path
    let path = url.resolvingSymlinksInPath().path
    if path == workspace { return "~" }
    if path.hasPrefix(workspace + "/") {
        return "~/" + EditorController.quoted(String(path.dropFirst(workspace.count + 1)))
    }
    return EditorController.quoted(path)
}

/// Reads and writes the [user] section of the app's ~/.gitconfig (the fake HOME the Python side uses).
enum GitConfig {
    static var url: URL {
        URL.applicationSupportDirectory.appending(path: "PocketCode/home/.gitconfig")
    }

    static func value(_ section: String, _ key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[\(section)]"
            } else if inSection, let eq = line.firstIndex(of: "=") {
                if line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == key {
                    return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    static func set(_ section: String, _ key: String, _ value: String) {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        var sectionIndex: Int?
        var keyIndex: Int?
        var inSection = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[\(section)]"
                if inSection { sectionIndex = i }
            } else if inSection, let eq = line.firstIndex(of: "="),
                      line[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == key {
                keyIndex = i
            }
        }
        let entry = "\t\(key) = \(value)"
        if let keyIndex {
            if value.isEmpty { lines.remove(at: keyIndex) } else { lines[keyIndex] = entry }
        } else if !value.isEmpty {
            if let sectionIndex {
                lines.insert(entry, at: sectionIndex + 1)
            } else {
                if lines.last?.isEmpty == true { lines.removeLast() }
                lines += ["[\(section)]", entry, ""]
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

enum Keychain {
    private static let service = "io.ubiship.PocketCode"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
