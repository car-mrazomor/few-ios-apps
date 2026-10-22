import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    @Environment(AppModel.self) private var app
    @State private var generating = false
    @State private var importing = false

    var body: some View {
        List {
            ForEach(app.keys) { key in
                NavigationLink {
                    KeyDetailView(keyID: key.id)
                } label: {
                    KeyRow(key: key)
                }
            }
            .onDelete { offsets in
                offsets.map { app.keys[$0] }.forEach(app.delete)
            }
        }
        .overlay {
            if app.keys.isEmpty {
                ContentUnavailableView {
                    Label("No Keys", systemImage: "key")
                } description: {
                    Text("Generate a new key on this iPhone, or import a key you already use, like ~/.ssh/id_ed25519.")
                } actions: {
                    Button("Generate Key") { generating = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import Key") { importing = true }
                }
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            Menu {
                Button { generating = true } label: { Label("Generate New Key", systemImage: "wand.and.stars") }
                Button { importing = true } label: { Label("Import Existing Key", systemImage: "square.and.arrow.down") }
            } label: {
                Label("Add Key", systemImage: "plus")
            }
        }
        .sheet(isPresented: $generating) { GenerateKeyView() }
        .sheet(isPresented: $importing) { ImportKeyView() }
    }
}

private struct KeyRow: View {
    let key: SSHKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.name).font(.headline)
                KeyTypeBadge(type: key.type)
            }
            Text(HostKeyFingerprint.sha256(key.publicKey))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

struct KeyTypeBadge: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Detail

private struct KeyDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let keyID: UUID

    @State private var copied: String?
    @State private var confirmingDelete = false

    private var key: SSHKey? { app.key(keyID) }

    private var installCommand: String {
        guard let key else { return "" }
        return "mkdir -p ~/.ssh && echo '\(key.publicKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    var body: some View {
        if let key {
            Form {
                Section {
                    TextField("Name", text: nameBinding)
                    LabeledContent("Type") { KeyTypeBadge(type: key.type) }
                    LabeledContent("Created", value: key.createdAt.formatted(date: .abbreviated, time: .omitted))
                }

                Section {
                    Text(key.publicKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    copyButton("Copy Public Key", value: key.publicKey)
                    ShareLink(item: key.publicKey) {
                        Label("Share Public Key", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Public Key")
                } footer: {
                    Text(HostKeyFingerprint.sha256(key.publicKey)).font(.caption2.monospaced())
                }

                Section {
                    Text(installCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    copyButton("Copy Install Command", value: installCommand)
                } header: {
                    Text("Add to a Server")
                } footer: {
                    Text("Run this once on the server (logged in with your password or another key). After that, set the server's authentication to this key.")
                }

                let users = app.hosts.filter { $0.auth == .key(key.id) }
                if !users.isEmpty {
                    Section("Used By") {
                        ForEach(users) { Text($0.displayName) }
                    }
                }

                Section {
                    Button("Delete Key", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text("The private key never leaves this device's Keychain.")
                }
            }
            .navigationTitle(key.name)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete \(key.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Key", role: .destructive) {
                    app.delete(key)
                    dismiss()
                }
            } message: {
                Text("Servers using this key will switch to password login. This can't be undone.")
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { key?.name ?? "" },
            set: { name in
                guard let i = app.keys.firstIndex(where: { $0.id == keyID }) else { return }
                app.keys[i].name = name
            }
        )
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = title
        } label: {
            Label(copied == title ? "Copied" : title, systemImage: copied == title ? "checkmark" : "doc.on.doc")
        }
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = nil
        }
    }
}

// MARK: - Generate

private struct GenerateKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = "iphone"
    @State private var type = KeyMaterial.Generated.ed25519
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(KeyMaterial.Generated.allCases) { type in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.title)
                                Text(type.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Key Type")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(working)
            .navigationTitle("Generate Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Generate") { generate() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func generate() {
        working = true
        error = nil
        let type = type
        let name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "iphone" : name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let key = try await Task.detached { try KeyMaterial.generate(type, name: name) }.value
                app.keys.append(key)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}

// MARK: - Import

struct ImportKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var text: String
    @State private var passphrase = ""
    @State private var needsPassphrase = false
    @State private var pickingFile = false
    @State private var working = false
    @State private var error: String?
    @FocusState private var passphraseFocused: Bool
    /// Name of a file that was opened or picked; used only if the key has no comment.
    @State private var fileName: String?

    init(text: String = "", fileName: String? = nil) {
        _text = State(initialValue: text)
        _fileName = State(initialValue: fileName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { pickingFile = true } label: {
                        Label("Choose File…", systemImage: "folder")
                    }
                    Button {
                        text = UIPasteboard.general.string ?? ""
                    } label: {
                        Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                    }
                } footer: {
                    Text("Tip: AirDrop a key file from your Mac (e.g. ~/.ssh/id_ed25519) and choose PocketShell to import it.")
                }

                Section {
                    TextEditor(text: $text)
                        .font(.caption2.monospaced())
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("-----BEGIN OPENSSH PRIVATE KEY-----\n…")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Private Key")
                } footer: {
                    Text("Ed25519, RSA (2048+) and ECDSA keys in OpenSSH, PEM or PKCS#8 format, with or without a passphrase.")
                }

                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .focused($passphraseFocused)
                        .onSubmit(importKey)
                } header: {
                    Text("Passphrase")
                } footer: {
                    Text(needsPassphrase ? "This key is encrypted. Enter its passphrase." : "Leave empty if the key has no passphrase.")
                        .foregroundStyle(needsPassphrase ? .orange : .secondary)
                }

                Section {
                    TextField("Name (optional)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Defaults to the key's comment (e.g. you@macbook) or the file name.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(working)
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Import", action: importKey)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                load(url)
            }
        }
        .interactiveDismissDisabled(working)
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let contents = String(data: data, encoding: .utf8) else {
            error = KeyImportError.unrecognized.localizedDescription
            return
        }
        text = contents
        fileName = url.deletingPathExtension().lastPathComponent
        error = nil
    }

    private func importKey() {
        working = true
        error = nil
        let (name, text, passphrase, fileName) = (name, text, passphrase, fileName)
        Task {
            do {
                // Passphrase-protected OpenSSH keys run bcrypt (deliberately slow), so keep it off the main thread.
                let key = try await Task.detached {
                    try KeyMaterial.importKey(name: name, text: text, passphrase: passphrase, fallbackName: fileName)
                }.value
                let blob = key.publicKey.split(separator: " ").prefix(2)
                if let existing = app.keys.first(where: { $0.publicKey.split(separator: " ").prefix(2) == blob }) {
                    KeyMaterial.delete(key.id)
                    self.error = "This key is already imported as \"\(existing.name)\"."
                    working = false
                    return
                }
                app.keys.append(key)
                dismiss()
            } catch KeyImportError.passphraseRequired {
                needsPassphrase = true
                passphraseFocused = true
                working = false
            } catch {
                self.error = error.localizedDescription
                if case KeyImportError.wrongPassphrase = error { passphraseFocused = true }
                working = false
            }
        }
    }
}
