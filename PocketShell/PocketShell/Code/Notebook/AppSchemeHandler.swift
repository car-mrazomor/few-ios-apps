import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `pocketcode://app/...` to the notebook web view:
///   /notebook/...   the notebook UI (bundled)
///   /pyodide/...    Pyodide: core files are bundled; packages download once from the CDN and are cached for offline use
///   /workspace/...  files in the notebook's folder (read-only, never outside it)
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pocketcode"
    static let pyodideVersion = "314.0.7"

    private let workspaceRoot: URL
    private let stopped = NSHashTable<AnyObject>.weakObjects()
    private let lock = NSLock()

    private static let bundle = Bundle.main.bundleURL
    private static let cache: URL = {
        // Application Support, not Caches: downloaded packages should survive storage cleanup so notebooks work offline.
        let url = URL.applicationSupportDirectory.appending(path: "PocketCode/pyodide-\(pyodideVersion)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init(workspaceRoot: URL) {
        self.workspaceRoot = workspaceRoot.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let path = task.request.url?.path(percentEncoded: false) ?? "/"
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].split(separator: "/").contains("..") else {
            return fail(task, status: 404)
        }
        let (area, file) = (parts[0], parts[1])
        switch area {
        case "notebook":
            serve(task, file: Self.bundle.appending(path: "notebook/\(file)"))
        case "workspace":
            let url = workspaceRoot.appending(path: file).resolvingSymlinksInPath()
            guard url.path.hasPrefix(workspaceRoot.path + "/") else { return fail(task, status: 403) }
            serve(task, file: url)
        case "pyodide":
            let bundled = Self.bundle.appending(path: "pyodide/\(file)")
            let cached = Self.cache.appending(path: file)
            if FileManager.default.fileExists(atPath: bundled.path) {
                serve(task, file: bundled)
            } else if FileManager.default.fileExists(atPath: cached.path) {
                serve(task, file: cached)
            } else {
                download(task, file: file, to: cached)
            }
        default:
            fail(task, status: 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        lock.lock()
        stopped.add(task)
        lock.unlock()
    }

    // MARK: Responses

    private func isStopped(_ task: any WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped.contains(task)
    }

    private func serve(_ task: any WKURLSchemeTask, file: URL) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return fail(task, status: 404)
        }
        respond(task, data: data, mimeType: Self.mimeType(for: file))
    }

    private func respond(_ task: any WKURLSchemeTask, data: Data, mimeType: String, status: Int = 200) {
        DispatchQueue.main.async { [self] in
            guard !isStopped(task), let url = task.request.url else { return }
            let headers = [
                "Content-Type": mimeType,
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
                // Cross-origin isolation enables SharedArrayBuffer, which Pyodide uses to interrupt running code.
                "Cross-Origin-Opener-Policy": "same-origin",
                "Cross-Origin-Embedder-Policy": "require-corp",
                "Cross-Origin-Resource-Policy": "cross-origin",
                "Cache-Control": "no-cache",
            ]
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private func fail(_ task: any WKURLSchemeTask, status: Int) {
        respond(task, data: Data("Not found".utf8), mimeType: "text/plain", status: status)
    }

    private func download(_ task: any WKURLSchemeTask, file: String, to destination: URL) {
        guard let remote = URL(string: "https://cdn.jsdelivr.net/pyodide/v\(Self.pyodideVersion)/full/\(file)") else {
            return fail(task, status: 404)
        }
        URLSession.shared.downloadTask(with: remote) { [self] location, response, error in
            guard let location, let http = response as? HTTPURLResponse, http.statusCode == 200, error == nil else {
                return fail(task, status: (response as? HTTPURLResponse)?.statusCode ?? 502)
            }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                serve(task, file: destination)
            } catch {
                fail(task, status: 500)
            }
        }.resume()
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "wasm": "application/wasm"
        case "py", "txt", "csv", "md": "text/plain; charset=utf-8"
        default: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
