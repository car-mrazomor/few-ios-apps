#if DEBUG
import Foundation

/// Simulator test hook: `SIMCTL_CHILD_PS_TEST_HOST=127.0.0.1:2222` etc. opens a session at launch.
/// Compiled out of release builds.
enum DebugLaunch {
    @MainActor
    static func run(_ app: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let theme = env["PS_TEST_THEME"] { app.themeID = theme }
        guard let target = env["PS_TEST_HOST"], let user = env["PS_TEST_USER"],
              let keyPath = env["PS_TEST_KEY"],
              let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return }

        let parts = target.split(separator: ":")
        var host = Host(name: "test-server", hostname: String(parts[0]), port: parts.count > 1 ? Int(parts[1]) ?? 22 : 22, username: user)
        if let key = try? KeyMaterial.importKey(name: "test", text: keyText, passphrase: env["PS_TEST_PASSPHRASE"]) {
            app.keys = [key]
            host.auth = .key(key.id)
        }
        app.hosts = [host]
        if let known = env["PS_TEST_KNOWN_HOST"] {
            app.knownHosts[host.knownHostsID] = known
        }
        if env["PS_TEST_CONNECT"] != nil {
            app.connect(host)
        }
    }
}
#endif
