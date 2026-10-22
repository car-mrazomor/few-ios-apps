#if DEBUG
import Foundation

/// Simulator test hook (compiled out of release builds), driven by SIMCTL_CHILD_* environment variables:
///   PC_TEST_FILES   "name=content‖name=content" files written into the workspace first (\n allowed)
///   PC_TEST_RUN     terminal commands separated by "‖", each run after the previous one finishes
///   PC_TEST_OPEN    workspace-relative file to open in the editor afterwards
///   PC_TEST_KEYS    keys fed to the editor, separated by "‖" (e.g. "j‖d‖d‖<Esc>")
///   PC_TEST_NOTEBOOK_JS  JavaScript run in the opened notebook once its kernel is ready (e.g. "runAll()")
///   PC_TEST_TAB     files | editor | terminal | settings
/// Terminal output is mirrored to Library/Caches/terminal.log.
enum CodeDebugLaunch {
    @MainActor
    static func run(_ app: CodeModel) {
        let env = ProcessInfo.processInfo.environment
        guard env.keys.contains(where: { $0.hasPrefix("PC_TEST_") }) else { return }
        app.activate()

        // Mirror terminal output to Library/Caches/terminal.log so tests can read it without screenshots.
        let log = URL.cachesDirectory.appending(path: "terminal.log")
        try? Data().write(to: log)
        if let handle = try? FileHandle(forWritingTo: log) {
            CodeTerminalSession.transcript = { handle.write(Data($0.utf8)) }
        }

        for spec in (env["PC_TEST_FILES"] ?? "").split(separator: "‖") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let url = app.workspace.appending(path: parts[0])
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? parts[1].replacingOccurrences(of: "\\n", with: "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        Task {
            for command in (env["PC_TEST_RUN"] ?? "").split(separator: "‖").map(String.init) {
                await waitForPrompt(app)
                app.terminal.run(command)
                try? await Task.sleep(for: .milliseconds(200))
            }
            await waitForPrompt(app)
            if let file = env["PC_TEST_OPEN"] {
                app.open(app.workspace.appending(path: file))
                try? await Task.sleep(for: .milliseconds(500))
                for key in (env["PC_TEST_KEYS"] ?? "").split(separator: "‖").map(String.init) {
                    (app.currentDocument as? EditorController)?.key(key)
                }
                if let script = env["PC_TEST_NOTEBOOK_JS"], let notebook = app.currentDocument as? NotebookController {
                    for _ in 0..<300 {
                        let ready = try? await notebook.webView.evaluateJavaScript("app.kernelReady") as? Bool
                        if ready == true { break }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    _ = try? await notebook.webView.evaluateJavaScript(script)
                }
            }
            switch env["PC_TEST_TAB"] {
            case "files": app.tab = .files
            case "editor": app.tab = .editor
            case "terminal": app.tab = .terminal
            case "settings": app.showingSettings = true
            case "servers": app.tab = .servers
            default: break
            }
            app.filesChanged()
        }
    }

    @MainActor
    private static func waitForPrompt(_ app: CodeModel) async {
        for _ in 0..<600 {
            if case .command = app.terminal.mode { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
