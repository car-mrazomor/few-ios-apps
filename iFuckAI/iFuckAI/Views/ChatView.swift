import PhotosUI
import SwiftUI

struct ChatsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack(path: $app.chatPath) {
            List {
                ForEach(chats.chats) { chat in
                    NavigationLink(value: chat.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chat.title)
                                .lineLimit(1)
                            Text(chat.updated, style: .relative)
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                        }
                    }
                    .themedRow()
                }
                .onDelete { offsets in
                    offsets.map { chats.chats[$0] }.forEach(chats.delete)
                }
            }
            .themedList()
            .overlay {
                if chats.chats.isEmpty {
                    VStack(spacing: 24) {
                        Logo(size: 110)
                        Greeting(name: settings.userName, size: 28)
                        Button("New Chat") { app.chatPath.append(app.newChat()) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.chatPath.append(app.newChat())
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Chat")
                }
            }
            .navigationDestination(for: UUID.self) { ChatView(chatID: $0) }
        }
    }
}

struct ChatView: View {
    let chatID: UUID

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme

    @State private var input = ""
    @State private var attachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @FocusState private var focused: Bool

    private var chat: Chat {
        chats.chat(chatID) ?? (app.draftID == chatID ? app.draft : nil) ?? Chat(id: chatID, title: "New chat", messages: [], updated: Date())
    }

    private var generatingHere: Bool { app.generatingChat == chatID }
    private var vision: Bool { app.loadedInfo?.vision == true }

    var body: some View {
        messages
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .background(theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ModelMenu(title: chat.title) }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        app.regenerate(in: chatID)
                    } label: {
                        Label("Regenerate Reply", systemImage: "arrow.clockwise")
                    }
                    .disabled(chat.messages.last?.role != .assistant || app.isGenerating || app.loaded == nil)
                    Button {
                        let text = chat.messages.map { "\($0.role == .user ? "You" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy Conversation", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                       let attachment = Media.storeImage(image) {
                        attachments.append(attachment)
                    }
                }
                photoItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let attachment = Media.storeImage(image) { attachments.append(attachment) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: Media.documentTypes + [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addFile(url) }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty { empty }
                    ForEach(chat.messages) { message in
                        MessageView(message: message, streaming: generatingHere && message.id == chat.messages.last?.id)
                            .equatable()
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .background(theme.background)
            .scrollDismissesKeyboard(.interactively)
            .modifier(StickToBottom(trigger: (chat.messages.last?.text.count ?? 0) + (chat.messages.last?.sources?.count ?? 0), streaming: generatingHere, proxy: proxy))
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Logo(size: 88)
            Greeting(name: settings.userName, size: 26)
                .padding(.bottom, 8)
            if let model = app.loaded {
                Text(model.title)
                    .font(.headline)
                Text(vision ? "Ask anything, or attach photos, camera shots and files with +." : "Ask anything, or attach text and PDF files with +.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No model loaded")
                    .font(.headline)
                Text(library.models.isEmpty ? "Download a model in Discover to start chatting." : "Pick a model from the menu at the top.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if library.models.isEmpty {
                    Button("Discover Models") { app.tab = .discover }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { attachment in
                            AttachmentThumbnail(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                }
                if settings.webSearch {
                Label("Web search is on. Your message is sent to DuckDuckGo, the reply is still made on your phone.", systemImage: "globe")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 6)
            }
            if attachments.contains(where: { $0.kind == .image }) && !vision {
                    Label("The loaded model can't see images. Load a model with a Vision badge.", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            GlassGroup(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                        Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                        Button { showFiles = true } label: { Label("File", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.text)
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                            .glass(Circle(), interactive: true)
                    }
                    .accessibilityLabel("Attach")
                    Button {
                        settings.webSearch.toggle()
                    } label: {
                        Image(systemName: "globe")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(settings.webSearch ? theme.onAccent : theme.text)
                            .frame(width: 46, height: 46)
                            .contentShape(Circle())
                            .glass(Circle(), tint: settings.webSearch ? theme.accent : nil, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.webSearch ? "Web search on" : "Web search off")
                    TextField(app.loaded == nil ? "Load a model to chat" : "Message", text: $input, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .glass(RoundedRectangle(cornerRadius: 23, style: .continuous))
                    if generatingHere {
                        Button { app.stop() } label: {
                            Image(systemName: "stop.fill")
                                .font(.headline)
                                .foregroundStyle(theme.onAccent)
                                .frame(width: 46, height: 46)
                                .contentShape(Circle())
                                .glass(Circle(), tint: theme.accent, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(canSend ? theme.onAccent : theme.secondary)
                                .frame(width: 46, height: 46)
                                .contentShape(Circle())
                                .glass(Circle(), tint: canSend ? theme.accent : nil, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .accessibilityLabel("Send")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var canSend: Bool {
        app.loaded != nil && !app.isGenerating && app.loadingID == nil
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && (vision || !attachments.contains { $0.kind == .image })
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        app.send(text, attachments: attachments, in: chatID, webSearch: settings.webSearch)
        input = ""
        attachments = []
    }

    private func addFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            if let image = UIImage(contentsOfFile: url.path), let attachment = Media.storeImage(image) {
                attachments.append(attachment)
            }
        } else if let attachment = Media.document(url) {
            attachments.append(attachment)
        } else {
            app.alert = "Couldn't read text from \(url.lastPathComponent)."
        }
    }
}

struct ModelMenu: View {
    let title: String
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library

    var body: some View {
        Menu {
            ForEach(library.models) { model in
                Button {
                    Task { await app.load(model) }
                } label: {
                    if app.loaded?.id == model.id {
                        Label(model.title, systemImage: "checkmark")
                    } else {
                        Label(model.title, systemImage: model.hasVision ? "eye" : "text.bubble")
                    }
                }
            }
            Divider()
            Button {
                app.tab = .models
            } label: {
                Label("Manage Models", systemImage: "shippingbox")
            }
            if app.loaded != nil {
                Button(role: .destructive) {
                    Task { await app.unload() }
                } label: {
                    Label("Unload Model", systemImage: "eject")
                }
            }
        } label: {
            VStack(spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if app.loadingID != nil {
                        ProgressView().controlSize(.mini)
                        Text("Loading…")
                    } else {
                        Circle()
                            .fill(app.loaded == nil ? Color.gray : Color.green)
                            .frame(width: 6, height: 6)
                        Text(app.loaded?.title ?? "No model")
                        if app.loadedInfo?.vision == true { Image(systemName: "eye") }
                    }
                    Image(systemName: "chevron.down")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: 220)
        }
        .disabled(app.isGenerating)
    }
}

struct StickToBottom: ViewModifier {
    let trigger: Int
    let streaming: Bool
    let proxy: ScrollViewProxy
    @State private var atBottom = true
    @State private var last = Date.distantPast

    func body(content: Content) -> some View {
        tracked(content.defaultScrollAnchor(.bottom))
            .onChange(of: trigger) { _, _ in
                guard atBottom, Date().timeIntervalSince(last) > 0.12 else { return }
                last = Date()
                jump()
            }
            .onChange(of: streaming) { _, now in
                if !now && atBottom {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { jump() }
                }
            }
    }

    private func jump() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    @ViewBuilder
    private func tracked<V: View>(_ view: V) -> some View {
        if #available(iOS 18.0, *) {
            view.onScrollGeometryChange(for: Bool.self) { g in
                g.visibleRect.maxY >= g.contentSize.height - 140
            } action: { _, value in
                atBottom = value
            }
        } else {
            view
        }
    }
}
