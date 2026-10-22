import SwiftUI

struct HostEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var host: Host
    @State private var password: String
    @State private var saveError: String?
    private let isNew: Bool

    init(host: Host) {
        _host = State(initialValue: host)
        _password = State(initialValue: Keychain.password(for: host.id) ?? "")
        isNew = host.hostname.isEmpty
    }

    private var isValid: Bool {
        !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(host.port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $host.name)
                }
                Section("Connection") {
                    TextField("Hostname or IP", text: $host.hostname)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    TextField("Username", text: $host.username)
                        .textContentType(.username)
                    LabeledContent("Port") {
                        TextField("22", value: $host.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section {
                    Picker("Method", selection: $host.auth) {
                        Text("Password").tag(Host.Auth.password)
                        ForEach(app.keys) { key in
                            Text("Key: \(key.name) (\(key.type))").tag(Host.Auth.key(key.id))
                        }
                    }
                    if host.auth == .password {
                        SecureField("Password (leave empty to ask)", text: $password)
                            .textContentType(.password)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    if app.keys.isEmpty {
                        Text("Create or import a key under Keys to use key authentication.")
                    }
                }
            }
            .alert("Couldn't Save Password", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .navigationTitle(isNew ? "New Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        do {
            try Keychain.setPassword(host.auth == .password ? password : nil, for: host.id)
        } catch {
            saveError = error.localizedDescription
            return
        }
        app.upsert(host)
        dismiss()
    }
}
