import Citadel
import Foundation
import NIOCore
import NIOSSH
import Observation
import SwiftTerm
import UIKit

/// One SSH connection rendered into a SwiftTerm view.
@MainActor @Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case connecting, connected, closed(String?)
    }

    enum Prompt: Equatable {
        case password
        case newHostKey(type: String, fingerprint: String)
        case changedHostKey(type: String, fingerprint: String)
    }

    enum PromptAnswer {
        case cancel, accept
        case password(String, save: Bool)
    }

    private enum Input {
        case data([UInt8])
        case resize(cols: Int, rows: Int)
    }

    let id = UUID()
    let host: Host
    var title: String
    var state: State = .connecting
    var prompt: Prompt?

    @ObservationIgnored let terminalView: ShellTerminalView
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var client: SSHClient?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var input: AsyncStream<Input>.Continuation?
    @ObservationIgnored private var promptContinuation: CheckedContinuation<PromptAnswer, Never>?

    init(host: Host, app: AppModel) {
        self.host = host
        self.app = app
        self.title = host.displayName
        terminalView = ShellTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: app.fontSize, weight: .regular))
        terminalView.installKeyBar(theme: app.theme)
        terminalView.apply(theme: app.theme, fontSize: app.fontSize)
        terminalView.terminalDelegate = self
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        state = .connecting
        task = Task { await run() }
    }

    func reconnect() {
        disconnect()
        task = nil
        terminalView.feed(text: "\r\n")
        start()
    }

    func disconnect() {
        task?.cancel()
        input?.finish()
        answer(.cancel)
        if let client {
            Task { try? await client.close() }
        }
        client = nil
    }

    private func run() async {
        do {
            let methods = try await authenticationMethods()
            let validator = HostKeyValidator { [weak self] key in
                await self?.verifyHostKey(key) ?? false
            }
            terminalView.feed(text: "Connecting to \(host.hostname):\(host.port)…\r\n")

            let client = try await connect(methods, validator: validator)
            self.client = client
            try Task.checkCancellation()
            state = .connected

            let terminal = terminalView.getTerminal()
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: terminal.cols,
                terminalRowHeight: terminal.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )

            // Citadel reports a non-zero exit by throwing, then throws again closing the
            // already-closed channel; capture the status inside and treat the close as normal.
            var exitStatus = 0
            do {
                try await client.withPTY(request) { inbound, outbound in
                    // Keystrokes and resizes go through one queue so they reach the server in order.
                    let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
                    self.input = continuation
                    let writer = Task {
                        for await item in stream {
                            switch item {
                            case .data(let bytes):
                                try? await outbound.write(ByteBuffer(bytes: bytes))
                            case .resize(let cols, let rows):
                                try? await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                            }
                        }
                    }
                    defer {
                        writer.cancel()
                        continuation.finish()
                    }
                    // Catch up on any resize that happened while the channel was opening.
                    let now = self.terminalView.getTerminal()
                    if now.cols != terminal.cols || now.rows != terminal.rows {
                        continuation.yield(.resize(cols: now.cols, rows: now.rows))
                    }

                    do {
                        for try await output in inbound {
                            switch output {
                            case .stdout(let buffer), .stderr(let buffer):
                                self.terminalView.feed(byteArray: Array(buffer: buffer)[...])
                            }
                        }
                    } catch let error as SSHClient.CommandFailed {
                        exitStatus = error.exitCode
                    }
                }
            } catch ChannelError.alreadyClosed {}
            finish(exitStatus == 0 ? nil : "exit status \(exitStatus)")
        } catch is CancellationError {
            finish(nil)
        } catch {
            finish(Self.describe(error))
        }
    }

    private func finish(_ message: String?) {
        input = nil
        if let client {
            Task { try? await client.close() }
        }
        client = nil
        state = .closed(message)
        let detail = message.map { ": \($0)" } ?? ""
        terminalView.feed(text: "\r\n\u{1B}[90m[Disconnected\(detail)]\u{1B}[0m\r\n")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        let text = String(describing: error)
        if text.contains("allAuthenticationOptionsFailed") { return "Authentication failed" }
        if text.contains("connectTimeout") { return "Connection timed out" }
        if text.contains("connectionRefused") || text.contains("Connection refused") { return "Connection refused" }
        return text
    }

    // MARK: Auth & host keys

    private struct AuthCancelled: LocalizedError {
        var errorDescription: String? { "Cancelled" }
    }

    /// Tries each auth method on its own connection until one is accepted (RSA: rsa-sha2-512, then rsa-sha2-256).
    private func connect(_ methods: [SSHAuthenticationMethod], validator: HostKeyValidator) async throws -> SSHClient {
        for (index, method) in methods.enumerated() {
            do {
                return try await SSHClient.connect(
                    host: host.hostname,
                    port: host.port,
                    authenticationMethod: method,
                    hostKeyValidator: .custom(validator),
                    reconnect: .never,
                    connectTimeout: .seconds(15)
                )
            } catch SSHClientError.allAuthenticationOptionsFailed where index < methods.count - 1 {
                continue
            }
        }
        throw SSHClientError.allAuthenticationOptionsFailed
    }

    private func authenticationMethods() async throws -> [SSHAuthenticationMethod] {
        switch host.auth {
        case .key(let keyID):
            return try KeyMaterial.load(keyID).authenticationMethods(username: host.username)
        case .password:
            if let saved = Keychain.password(for: host.id) {
                return [.passwordBased(username: host.username, password: saved)]
            }
            guard case .password(let password, let save) = await ask(.password) else { throw AuthCancelled() }
            if save {
                do {
                    try Keychain.setPassword(password, for: host.id)
                } catch {
                    terminalView.feed(text: "\u{1B}[33m\(error.localizedDescription)\u{1B}[0m\r\n")
                }
            }
            return [.passwordBased(username: host.username, password: password)]
        }
    }

    private func verifyHostKey(_ key: String) async -> Bool {
        let type = String(key.split(separator: " ").first ?? "")
        let fingerprint = HostKeyFingerprint.sha256(key)
        switch app.knownHosts[host.knownHostsID] {
        case key:
            return true
        case nil:
            guard case .accept = await ask(.newHostKey(type: type, fingerprint: fingerprint)) else { return false }
        case .some:
            guard case .accept = await ask(.changedHostKey(type: type, fingerprint: fingerprint)) else { return false }
        }
        app.knownHosts[host.knownHostsID] = key
        return true
    }

    private func ask(_ prompt: Prompt) async -> PromptAnswer {
        answer(.cancel)
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            self.prompt = prompt
        }
    }

    func answer(_ answer: PromptAnswer) {
        prompt = nil
        promptContinuation?.resume(returning: answer)
        promptContinuation = nil
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        _ = MainActor.assumeIsolated { input?.yield(.data(bytes)) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        _ = MainActor.assumeIsolated { input?.yield(.resize(cols: newCols, rows: newRows)) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            self.title = title.isEmpty ? host.displayName : title
        }
    }

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

    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
}

// MARK: - Host key validation

/// Bridges NIO's callback-based host key check to an async decision on the main actor.
private final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Rejected: LocalizedError {
        var errorDescription: String? { "Host key not trusted" }
    }

    let decide: @Sendable (String) async -> Bool

    init(decide: @escaping @Sendable (String) async -> Bool) {
        self.decide = decide
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        Task {
            if await decide(key) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(Rejected())
            }
        }
    }
}
