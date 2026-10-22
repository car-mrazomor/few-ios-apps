import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var app

    private var selected: TerminalSession? {
        app.sessions.first { $0.id == app.selectedSessionID } ?? app.sessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            if let session = selected {
                SessionPane(session: session)
                    .id(session.id)
            } else {
                Spacer()
            }
        }
        .background(Color(uiColor: app.theme.backgroundColor))
        .tint(Color(uiColor: app.theme.accentColor))
        .preferredColorScheme(app.theme.isDark ? .dark : .light)
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Button {
                app.showingTerminal = false
            } label: {
                Image(systemName: "server.rack")
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("Servers")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(app.sessions) { session in
                        TabChip(session: session, isSelected: session.id == (app.selectedSessionID ?? app.sessions.first?.id))
                    }
                }
            }

            Menu {
                Picker("Theme", selection: Bindable(app).themeID) {
                    ForEach(Theme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Divider()
                Button {
                    app.fontSize = min(24, app.fontSize + 1)
                } label: {
                    Label("Larger Text", systemImage: "textformat.size.larger")
                }
                Button {
                    app.fontSize = max(9, app.fontSize - 1)
                } label: {
                    Label("Smaller Text", systemImage: "textformat.size.smaller")
                }
            } label: {
                Image(systemName: "paintpalette")
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("Appearance")

            Menu {
                ForEach(app.hosts) { host in
                    Button(host.displayName) { app.connect(host) }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 32)
            }
            .accessibilityLabel("New Session")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: app.theme.backgroundColor).overlay(.ultraThinMaterial))
    }
}

private struct TabChip: View {
    @Environment(AppModel.self) private var app
    let session: TerminalSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(session.title)
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 140)
            Button {
                app.close(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close \(session.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color(uiColor: app.theme.accentColor).opacity(0.25) : Color.clear, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { app.selectedSessionID = session.id }
    }

    private var statusColor: Color {
        switch session.state {
        case .connecting: .yellow
        case .connected: .green
        case .closed: .gray
        }
    }
}

private struct SessionPane: View {
    @Bindable var session: TerminalSession
    @State private var password = ""

    var body: some View {
        TerminalHost(view: session.terminalView)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay(alignment: .bottom) {
                if case .closed = session.state {
                    Button {
                        session.reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
            .alert("Password for \(session.host.username)@\(session.host.hostname)", isPresented: isPrompting(.password)) {
                SecureField("Password", text: $password)
                Button("Connect") { submitPassword(save: false) }
                Button("Connect & Save") { submitPassword(save: true) }
                Button("Cancel", role: .cancel) { session.answer(.cancel) }
            }
            .alert("Unknown Server", isPresented: isPrompting(hostKeyPrompt: false)) {
                Button("Trust & Connect") { session.answer(.accept) }
                Button("Cancel", role: .cancel) { session.answer(.cancel) }
            } message: {
                Text(hostKeyMessage(intro: "This is the first connection to \(session.host.hostname). Verify the fingerprint before trusting it."))
            }
            .alert("⚠️ Host Key Changed", isPresented: isPrompting(hostKeyPrompt: true)) {
                Button("Cancel", role: .cancel) { session.answer(.cancel) }
                Button("Replace Key & Connect", role: .destructive) { session.answer(.accept) }
            } message: {
                Text(hostKeyMessage(intro: "The key for \(session.host.hostname) is different from the one you trusted before. This can mean the server was reinstalled, or that someone is intercepting the connection."))
            }
    }

    private func submitPassword(save: Bool) {
        session.answer(.password(password, save: save))
        password = ""
    }

    private func hostKeyMessage(intro: String) -> String {
        switch session.prompt {
        case .newHostKey(let type, let fingerprint), .changedHostKey(let type, let fingerprint):
            "\(intro)\n\n\(type)\n\(fingerprint)"
        default:
            intro
        }
    }

    private func isPrompting(_ prompt: TerminalSession.Prompt) -> Binding<Bool> {
        binding { $0 == prompt }
    }

    private func isPrompting(hostKeyPrompt changed: Bool) -> Binding<Bool> {
        binding {
            switch $0 {
            case .newHostKey: !changed
            case .changedHostKey: changed
            default: false
            }
        }
    }

    private func binding(_ matches: @escaping (TerminalSession.Prompt) -> Bool) -> Binding<Bool> {
        Binding(
            get: { session.prompt.map(matches) ?? false },
            set: { presented in
                if !presented, let prompt = session.prompt, matches(prompt) {
                    session.answer(.cancel)
                }
            }
        )
    }
}

/// Hosts the session's long-lived SwiftTerm view so scrollback survives tab switches.
private struct TerminalHost: UIViewRepresentable {
    let view: ShellTerminalView

    func makeUIView(context: Context) -> ShellTerminalView {
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: ShellTerminalView, context: Context) {}
}
