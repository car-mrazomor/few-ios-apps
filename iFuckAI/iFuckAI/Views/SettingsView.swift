import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var chats: ChatStore

    @State private var confirmDeleteChats = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section("Appearance") {
                    LabeledContent("Your name") {
                        TextField("User", text: $settings.userName)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.givenName)
                    }
                    ThemePicker()
                        .padding(.vertical, 6)
                    Button("Show Welcome Screen") { settings.onboarded = false }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("System prompt", text: $settings.systemPrompt, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Temperature", value: String(format: "%.2f", settings.temperature))
                        Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                    }
                    Picker("Context length", selection: $settings.contextLength) {
                        ForEach(AppSettings.contextOptions, id: \.self) { Text("\($0 / 1024)K tokens").tag($0) }
                    }
                    Stepper("Max reply: \(settings.maxTokens) tokens", value: $settings.maxTokens, in: 256...8192, step: 256)
                    if let info = app.loadedInfo, info.contextLength != min(settings.contextLength, info.trainContextLength > 0 ? info.trainContextLength : settings.contextLength) {
                        Button("Reload model with new context length") {
                            Task { await app.reloadWithNewContext() }
                        }
                        .disabled(app.isGenerating)
                    }
                } header: {
                    Text("Generation")
                } footer: {
                    Text("Longer context remembers more of the chat but uses more memory.")
                }

                Section {
                    Toggle("Notify when a reply is ready", isOn: $settings.notifications)
                        .onChange(of: settings.notifications) { _, on in if on { app.requestNotificationsIfNeeded() } }
                    Toggle("Background replies", isOn: $settings.backgroundCPU)
                    if app.loaded != nil && app.loadedOnCPU != settings.backgroundCPU {
                        Button("Reload model to apply") {
                            Task { await app.reloadWithNewContext() }
                        }
                        .disabled(app.isGenerating)
                    }
                } header: {
                    Text("Replies")
                } footer: {
                    Text("iOS doesn't let apps use the GPU in the background, so normally a reply pauses when you leave and continues when you come back. Background replies run the model on the CPU instead: slower, but it can keep going for a while after you leave and notify you when it's done.")
                }

                Section {
                    SecureField("hf_…", text: $settings.hfToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("Create a token on huggingface.co", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                } header: {
                    Text("Hugging Face access token")
                } footer: {
                    Text("Only needed for gated models. A read-only token is enough. Stored in the Keychain.")
                }

                Section("This iPhone") {
                    LabeledContent("Memory", value: Format.bytes(Int64(ProcessInfo.processInfo.physicalMemory)))
                    LabeledContent("Usable by apps", value: Format.bytes(Fit.memoryBudget))
                    LabeledContent("Measured bandwidth", value: String(format: "%.0f GB/s", Fit.bandwidth / 1e9))
                    LabeledContent("Free storage", value: Format.bytes(Paths.freeDiskBytes))
                    LabeledContent("Models", value: "\(library.models.count) · \(Format.bytes(library.totalBytes))")
                }

                Section {
                    Button("Delete All Chats", role: .destructive) { confirmDeleteChats = true }
                        .disabled(chats.chats.isEmpty || app.isGenerating)
                }

                Section("About") {
                    LabeledContent("Inference", value: "llama.cpp \(Architectures.llamaBuild)")
                    LabeledContent("Supported architectures", value: "\(Architectures.supported.count)")
                    Text("iFuck AI runs models fully on this device. Chats, photos and files never leave it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                }
                .themedRow()
            }
            .themedList()
            .navigationTitle("Settings")
            .confirmationDialog("Delete all chats?", isPresented: $confirmDeleteChats, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    chats.chats.forEach(chats.delete)
                }
            }
        }
    }
}
