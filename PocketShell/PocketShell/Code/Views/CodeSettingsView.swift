import SwiftUI

struct CodeSettingsView: View {
    @Environment(CodeModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var username = ""
    @State private var token = ""
    @State private var tokenError = false
    @State private var sizes: [StorageArea: Int64] = [:]
    @State private var clearing: StorageArea?
    @State private var storageError: String?

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    Toggle("Vim Mode", isOn: $app.vimEnabled)
                    Stepper(value: $app.fontSize, in: 10...22, step: 1) {
                        LabeledContent("Font Size", value: "\(Int(app.fontSize)) pt")
                    }
                } header: {
                    Text("Editor")
                } footer: {
                    Text("With vim mode off, the editor behaves like a normal text editor.")
                }

                Section {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                } header: {
                    Text("Git Identity")
                } footer: {
                    Text("Used as the author of your commits (git config --global user.name / user.email).")
                }

                Section {
                    TextField("GitHub username", text: $username)
                    SecureField("Personal access token", text: $token)
                    if !app.gitToken.isEmpty {
                        Button("Remove Token", role: .destructive) { removeToken() }
                    }
                } header: {
                    Text("Git Authentication")
                } footer: {
                    Text("Needed to push, and to clone private repos, over HTTPS. On GitHub: Settings → Developer settings → Personal access tokens (fine-grained) with Contents: read & write. Stored in this device's CodeKeychain, which iOS keeps even if you delete the app — remove the token here first if you stop using PocketCode.")
                }

                Section {
                    ForEach(StorageArea.allCases) { area in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(area.title)
                                Text(sizes[area].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Clear") { clearing = area }
                                .buttonStyle(.bordered)
                                .disabled((sizes[area] ?? 0) == 0)
                        }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Your projects in Files aren't affected. Everything here is deleted automatically if you delete the app.")
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Color(Gruvbox.bg0))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                }
            }
            .alert("Couldn't Save Token", isPresented: $tokenError) {
                Button("OK") { dismiss() }
            } message: {
                Text("The CodeKeychain refused to store it. Other settings were saved.")
            }
            .confirmationDialog(clearing?.title ?? "", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
                if let area = clearing {
                    Button("Clear \(area.title)", role: .destructive) { clear(area) }
                }
            } message: {
                Text(clearing?.explanation ?? "")
            }
            .alert("Couldn't Clear", isPresented: Binding(get: { storageError != nil }, set: { if !$0 { storageError = nil } })) {
                Button("OK") { storageError = nil }
            } message: {
                Text(storageError ?? "")
            }
            .task { await measure() }
            .onAppear {
                name = app.gitName
                email = app.gitEmail
                username = app.gitUsername
                token = app.gitToken
            }
        }
    }

    private func measure() async {
        for area in StorageArea.allCases {
            let size = await Task.detached { area.size() }.value
            sizes[area] = size
        }
    }

    private func clear(_ area: StorageArea) {
        do {
            try area.clear()
        } catch {
            storageError = error.localizedDescription
        }
        sizes[area] = nil
        Task { await measure() }
    }

    private func removeToken() {
        token = ""
        if !app.saveGitToken("") {
            tokenError = true
        }
    }

    private func save() {
        app.gitName = name.trimmingCharacters(in: .whitespaces)
        app.gitEmail = email.trimmingCharacters(in: .whitespaces)
        app.gitUsername = username.trimmingCharacters(in: .whitespaces)
        if token != app.gitToken, !app.saveGitToken(token.trimmingCharacters(in: .whitespaces)) {
            tokenError = true
            return
        }
        dismiss()
    }
}
