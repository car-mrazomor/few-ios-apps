import SwiftUI

struct HostListView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Host?

    var body: some View {
        @Bindable var app = app

        NavigationStack {
            List {
                ForEach(app.hosts) { host in
                    Button {
                        app.connect(host)
                    } label: {
                        HostRow(host: host, keyName: keyName(for: host))
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) { app.delete(host) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { editing = host } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { app.delete(host) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if app.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to connect over SSH.")
                    } actions: {
                        Button("Add Server") { editing = Host() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    NavigationLink {
                        KeysView()
                    } label: {
                        Label("Keys", systemImage: "key")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !app.sessions.isEmpty {
                        Button {
                            app.showingTerminal = true
                        } label: {
                            Label("Sessions (\(app.sessions.count))", systemImage: "terminal")
                        }
                    }
                    Button { editing = Host() } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host)
            }
            .sheet(item: $app.pendingImport) { pending in
                ImportKeyView(text: pending.text, fileName: pending.fileName)
            }
            .fullScreenCover(isPresented: $app.showingTerminal) {
                SessionsView()
            }
        }
    }

    private func keyName(for host: Host) -> String? {
        if case .key(let id) = host.auth { return app.key(id)?.name ?? "missing key" }
        return nil
    }
}

private struct HostRow: View {
    let host: Host
    let keyName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.headline)
                Text("\(host.username)@\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let keyName {
                Label(keyName, systemImage: "key.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
