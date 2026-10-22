import Foundation

struct Host: Identifiable, Codable, Hashable {
    enum Auth: Codable, Hashable {
        case password
        case key(UUID)
    }

    var id = UUID()
    var name = ""
    var hostname = ""
    var port = 22
    var username = ""
    var auth: Auth = .password

    var displayName: String { name.isEmpty ? "\(username)@\(hostname)" : name }

    /// Key used for the known-hosts table, like OpenSSH's `[host]:port`.
    var knownHostsID: String { "[\(hostname.lowercased())]:\(port)" }
}

struct SSHKey: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var type: String
    /// OpenSSH single-line public key (`ssh-ed25519 AAAA... name`).
    var publicKey: String
    var createdAt = Date()
}
