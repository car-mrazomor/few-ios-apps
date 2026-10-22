import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    var hosts: [Host] = [] { didSet { save(hosts, to: "hosts.json") } }
    var keys: [SSHKey] = [] { didSet { save(keys, to: "keys.json") } }
    /// `[host]:port` → OpenSSH public key line, trusted on first use.
    var knownHosts: [String: String] = [:] { didSet { save(knownHosts, to: "known_hosts.json") } }

    var themeID = UserDefaults.standard.string(forKey: "theme") ?? "black" {
        didSet {
            UserDefaults.standard.set(themeID, forKey: "theme")
            applyAppearance()
        }
    }
    var fontSize = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 13 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            applyAppearance()
        }
    }
    var theme: Theme { Theme.named(themeID) }

    /// A key file opened from Files / AirDrop, waiting for the import sheet.
    var pendingImport: PendingImport?

    struct PendingImport: Identifiable {
        let id = UUID()
        let text: String
        let fileName: String
    }

    var sessions: [TerminalSession] = []
    var selectedSessionID: UUID?
    var showingTerminal = false

    init() {
        hosts = load("hosts.json") ?? []
        keys = load("keys.json") ?? []
        knownHosts = load("known_hosts.json") ?? [:]
    }

    // MARK: Hosts

    func upsert(_ host: Host) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[i] = host
        } else {
            hosts.append(host)
        }
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        try? Keychain.setPassword(nil, for: host.id)
    }

    // MARK: Keys

    func delete(_ key: SSHKey) {
        keys.removeAll { $0.id == key.id }
        KeyMaterial.delete(key.id)
        for i in hosts.indices where hosts[i].auth == .key(key.id) {
            hosts[i].auth = .password
        }
    }

    func key(_ id: UUID) -> SSHKey? { keys.first { $0.id == id } }

    // MARK: Sessions

    func connect(_ host: Host) {
        let session = TerminalSession(host: host, app: self)
        sessions.append(session)
        selectedSessionID = session.id
        showingTerminal = true
        session.start()
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: i)
        if selectedSessionID == session.id {
            selectedSessionID = sessions.isEmpty ? nil : sessions[max(0, i - 1)].id
        }
        if sessions.isEmpty { showingTerminal = false }
    }

    /// Handles "Open in PocketShell" for a key file. The copy iOS placed in our Inbox is deleted right away.
    func openKeyFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let text = String(data: data, encoding: .utf8) else { return }
        showingTerminal = false
        pendingImport = PendingImport(text: text, fileName: url.deletingPathExtension().lastPathComponent)
    }

    private func applyAppearance() {
        for session in sessions {
            session.terminalView.apply(theme: theme, fontSize: fontSize)
        }
    }

    // MARK: Persistence

    private static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "PocketShell", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: Self.directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: Self.directory.appending(path: name), options: [.atomic, .completeFileProtection])
    }
}
