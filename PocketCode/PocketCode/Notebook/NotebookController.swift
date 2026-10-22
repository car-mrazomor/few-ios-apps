import Observation
import UIKit
import WebKit

/// An open .ipynb: a web view running the notebook UI with a Pyodide kernel.
@MainActor @Observable
final class NotebookController: NSObject, OpenDocument {
    let url: URL
    private(set) var isModified = false
    var name: String { url.lastPathComponent }

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var fontSize: Double
    @ObservationIgnored private var vimEnabled: Bool
    @ObservationIgnored var onFilesChanged: (() -> Void)?

    #if DEBUG
    static let debugLog = URL.cachesDirectory.appending(path: "notebook.log")

    /// Debug builds mirror the page's and kernel's log lines to Library/Caches/notebook.log.
    static func appendDebugLog(_ text: String) {
        if !FileManager.default.fileExists(atPath: debugLog.path) {
            FileManager.default.createFile(atPath: debugLog.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: debugLog) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
    }
    #endif
    private static let maxFileBytes = 20 * 1024 * 1024
    private static let maxTotalBytes = 200 * 1024 * 1024

    init(url: URL, fontSize: Double, vimEnabled: Bool) {
        self.url = url
        self.fontSize = fontSize
        self.vimEnabled = vimEnabled

        let configuration = WKWebViewConfiguration()
        let folder = url.deletingLastPathComponent()
        configuration.setURLSchemeHandler(AppSchemeHandler(workspaceRoot: folder), forURLScheme: AppSchemeHandler.scheme)
        let proxy = MessageProxy()
        configuration.userContentController.add(proxy, name: "pc")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = Gruvbox.bg0
        webView.scrollView.backgroundColor = Gruvbox.bg0
        webView.scrollView.keyboardDismissMode = .interactive
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        proxy.target = self
        webView.load(URLRequest(url: URL(string: "\(AppSchemeHandler.scheme)://app/notebook/index.html")!))
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        call("PC.setOptions({fontSize: \(Int(size))})")
    }

    func setVimEnabled(_ enabled: Bool) {
        vimEnabled = enabled
        call("PC.setOptions({vim: \(enabled)})")
    }

    func save() {
        call("PC.save()")
    }

    private func call(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: Messages from the page

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            loadNotebook()
        case "dirty":
            isModified = true
        case "debug":
            #if DEBUG
            if let text = message["text"] as? String { Self.appendDebugLog(text) }
            #endif
        case "save":
            guard let text = message["notebook"] as? String else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                isModified = false
            } catch {
                call("console.error('save failed')")
            }
        case "file":
            guard let path = message["path"] as? String, let encoded = message["data"] as? String,
                  let data = Data(base64Encoded: encoded), let target = fileURL(path) else { return }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
            onFilesChanged?()
        case "delete":
            guard let path = message["path"] as? String, let target = fileURL(path), target != url else { return }
            try? FileManager.default.removeItem(at: target)
            onFilesChanged?()
        default:
            break
        }
    }

    /// A path written by the kernel, only if it stays inside the notebook's folder.
    private func fileURL(_ relative: String) -> URL? {
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = root.appending(path: relative).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    private func loadNotebook() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let notebook = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : text
        let options: [String: Any] = ["vim": vimEnabled, "fontSize": Int(fontSize), "files": folderManifest()]
        guard let optionsJSON = try? JSONSerialization.data(withJSONObject: options),
              let optionsText = String(data: optionsJSON, encoding: .utf8) else { return }
        // The notebook text is JSON already; if it's malformed, start empty instead of breaking the page.
        let valid = (try? JSONSerialization.jsonObject(with: Data(notebook.utf8))) != nil
        call("PC.load(\(valid ? notebook : "{}"), \(optionsText))")
    }

    /// Files the kernel copies into Pyodide's file system so code can open them by relative path.
    private func folderManifest() -> [[String: Any]] {
        let root = url.deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [[String: Any]] = []
        var total = 0
        for case let file as URL in enumerator {
            if ["__pycache__", "node_modules", ".git"].contains(file.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size <= Self.maxFileBytes,
                  total + size <= Self.maxTotalBytes, file.pathExtension != "ipynb" else { continue }
            total += size
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
            files.append(["path": relative, "size": size])
            if files.count >= 2000 { break }
        }
        return files
    }

    static func emptyNotebook() -> String {
        """
        {
         "cells": [
          {"cell_type": "markdown", "id": "intro", "metadata": {}, "source": ["# New notebook\\n", "Shift-Enter (or ▶) runs a cell. Imports like `import pandas` install automatically; anything else: `%pip install name`."]},
          {"cell_type": "code", "execution_count": null, "id": "first", "metadata": {}, "outputs": [], "source": ["import numpy as np\\n", "np.arange(10) ** 2"]}
         ],
         "metadata": {"kernelspec": {"display_name": "Python 3 (Pyodide)", "language": "python", "name": "python3"}},
         "nbformat": 4,
         "nbformat_minor": 5
        }

        """
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the controller.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: NotebookController?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.receive(message.body) }
    }
}
