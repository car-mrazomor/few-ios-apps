import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum Tab: Hashable { case chat, discover, models, settings }

    let engine = LlamaEngine()
    let library = Library()
    let chats = ChatStore()
    let settings = AppSettings()
    let downloads = Downloads.shared

    @Published var tab = Tab.chat
    @Published var chatPath: [UUID] = []
    @Published private(set) var loaded: LocalModel?
    @Published private(set) var loadedInfo: LoadedModelInfo?
    @Published private(set) var loadingID: String?
    @Published private(set) var generatingChat: UUID?
    @Published var alert: String?

    @Published private(set) var loadedOnCPU = false

    private var imageCache: [UUID: EngineImage] = [:]
    private var paused: (chatID: UUID, replyID: UUID, weights: Int64)?
    private var pauseRequested = false
    private var isActive = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var askedForNotifications = false

    init() {
        Fit.recordMemoryBudget()
        chatPath = [newChat()]
        downloads.token = { [settings] in settings.hfToken }
        downloads.onComplete = { [weak self] model in
            self?.library.add(model)
        }
        NotificationCenter.default.addObserver(forName: .openChat, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            MainActor.assumeIsolated { self?.open(chat: id) }
        }
    }

    func open(chat id: UUID) {
        guard chats.chat(id) != nil else { return }
        tab = .chat
        chatPath = [id]
    }

    var isGenerating: Bool { generatingChat != nil }

    func load(_ model: LocalModel) async {
        guard loadingID == nil else { return }
        if loaded?.id == model.id { return }
        loadingID = model.id
        defer { loadingID = nil }
        paused = nil
        loaded = nil
        loadedInfo = nil
        imageCache = [:]
        do {
            let cpu = settings.backgroundCPU
            let info = try await engine.load(model: model.url.path, projector: model.projectorURL?.path,
                                             contextLength: settings.contextLength, gpu: !cpu)
            loaded = model
            loadedInfo = info
            loadedOnCPU = cpu
            UserDefaults.standard.set(model.id, forKey: "lastModel")
        } catch {
            alert = "\(model.title): \(error.localizedDescription)"
        }
    }

    func unload() async {
        paused = nil
        await engine.unload()
        loaded = nil
        loadedInfo = nil
        imageCache = [:]
    }

    func reloadWithNewContext() async {
        guard let model = loaded else { return }
        await unload()
        await load(model)
    }

    func restoreLastModel() async {
        guard loaded == nil, let id = UserDefaults.standard.string(forKey: "lastModel"), let model = library.model(id) else { return }
        let fit = Fit.evaluate(weights: model.sizeBytes, projector: model.projectorBytes, info: model.info, context: settings.contextLength)
        if fit.level == .good { await load(model) }
    }

    func delete(_ model: LocalModel) async {
        if loaded?.id == model.id { await unload() }
        library.delete(model)
    }

    func send(_ text: String, attachments: [Attachment], in chatID: UUID, webSearch: Bool = false) {
        guard var chat = chats.chat(chatID) ?? (chatID == draftID ? draft : nil), let model = loaded, !isGenerating else { return }
        if attachments.contains(where: { $0.kind == .image }) && loadedInfo?.vision != true {
            alert = EngineError.noVision.localizedDescription
            return
        }
        paused = nil
        let search = webSearch && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let user = Message(id: UUID(), role: .user, text: text, attachments: attachments)
        var reply = Message(id: UUID(), role: .assistant, text: "", model: model.title)
        if search { reply.status = "Searching the web…" }
        if chat.messages.isEmpty {
            let source = text.isEmpty ? (attachments.first?.name ?? "New chat") : text
            chat.title = String(source.prefix(60))
        }
        chat.messages += [user, reply]
        chat.updated = Date()
        chats.update(chat)
        if chatID == draftID { draft = nil }
        generatingChat = chat.id
        guard search else {
            generate(chat: chat, replyID: reply.id, weights: model.sizeBytes)
            return
        }
        Task {
            var current = chat
            do {
                let result = try await WebSearch.context(for: String(text.prefix(300)))
                if let u = current.messages.firstIndex(where: { $0.id == user.id }) { current.messages[u].webContext = result.context }
                if let r = current.messages.firstIndex(where: { $0.id == reply.id }) { current.messages[r].sources = result.sources }
            } catch {
                if let r = current.messages.firstIndex(where: { $0.id == reply.id }) {
                    current.messages[r].notice = "Web search failed: \(error.localizedDescription) Answering without it."
                }
            }
            if let r = current.messages.firstIndex(where: { $0.id == reply.id }) { current.messages[r].status = nil }
            chats.update(current)
            generate(chat: current, replyID: reply.id, weights: model.sizeBytes)
        }
    }

    func regenerate(in chatID: UUID) {
        guard var chat = chats.chat(chatID), loaded != nil, !isGenerating,
              let last = chat.messages.last, last.role == .assistant else { return }
        chat.messages[chat.messages.count - 1].text = ""
        chat.messages[chat.messages.count - 1].stats = nil
        chat.messages[chat.messages.count - 1].error = nil
        chat.messages[chat.messages.count - 1].notice = nil
        chats.update(chat)
        paused = nil
        engine.reset()
        generate(chat: chat, replyID: last.id, weights: loaded?.sizeBytes ?? 0)
    }

    func stop() {
        engine.stop()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            endBackgroundTask()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            if let p = paused, !isGenerating { resume(p) }
        case .inactive:
            isActive = false
            if isGenerating && !loadedOnCPU {
                pauseRequested = true
                engine.stop()
            }
        case .background:
            isActive = false
            if isGenerating && loadedOnCPU {
                beginBackgroundTask()
            } else if isGenerating || paused != nil {
                pauseRequested = true
                engine.stop()
                notifyPaused()
            }
        @unknown default:
            break
        }
    }

    @Published var draft: Chat?
    var draftID: UUID? { draft?.id }

    func newChat() -> UUID {
        let chat = Chat.new()
        draft = chat
        return chat.id
    }

    private func generate(chat: Chat, replyID: UUID, weights: Int64) {
        guard loaded != nil else {
            generatingChat = nil
            return
        }
        let history = chat.messages.filter { $0.id != replyID }
        var turns: [EngineTurn] = []
        let system = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            turns.append(EngineTurn(id: Self.systemID, role: .system, text: system))
        }
        for message in history {
            let images = message.attachments.filter { $0.kind == .image }.compactMap { image(for: $0) }
            turns.append(EngineTurn(id: message.id, role: message.role == .user ? .user : .assistant,
                                    text: Media.prompt(for: message), images: images))
        }
        generatingChat = chat.id
        consume(engine.generate(conversation: turns, replyID: replyID, settings: settings.engine), chat: chat, replyID: replyID, weights: weights)
    }

    private func resume(_ p: (chatID: UUID, replyID: UUID, weights: Int64)) {
        guard var chat = chats.chat(p.chatID), loaded != nil else {
            paused = nil
            return
        }
        paused = nil
        if let i = chat.messages.firstIndex(where: { $0.id == p.replyID }) { chat.messages[i].notice = nil }
        chats.update(chat, persist: false)
        generatingChat = chat.id
        consume(engine.resume(replyID: p.replyID, settings: settings.engine), chat: chat, replyID: p.replyID, weights: p.weights)
    }

    private func consume(_ stream: AsyncThrowingStream<EngineEvent, Error>, chat: Chat, replyID: UUID, weights: Int64) {
        pauseRequested = false
        Task {
            var current = chat
            var wasStopped = false
            var pending = ""
            var lastFlush = Date()
            @MainActor func apply(persist: Bool) {
                guard let i = current.messages.firstIndex(where: { $0.id == replyID }) else { return }
                current.messages[i].text += pending
                pending = ""
                current.updated = Date()
                chats.update(current, persist: persist)
            }
            do {
                for try await event in stream {
                    switch event {
                    case .text(let t):
                        pending += t
                        if Date().timeIntervalSince(lastFlush) > 0.08 {
                            apply(persist: false)
                            lastFlush = Date()
                        }
                    case .notice(let n):
                        if let i = current.messages.firstIndex(where: { $0.id == replyID }) { current.messages[i].notice = n }
                    case .done(let stats):
                        wasStopped = stats.stopped == true
                        if let i = current.messages.firstIndex(where: { $0.id == replyID }) {
                            var merged = stats
                            if let old = current.messages[i].stats {
                                merged.promptTokens = old.promptTokens
                                merged.promptSeconds = old.promptSeconds
                                merged.tokens += old.tokens
                                merged.seconds += old.seconds
                            }
                            current.messages[i].stats = merged
                        }
                        Fit.recordSpeed(weights: weights, tokensPerSecond: stats.tokensPerSecond, tokens: stats.tokens)
                    }
                }
            } catch {
                if let i = current.messages.firstIndex(where: { $0.id == replyID }) {
                    current.messages[i].error = error.localizedDescription
                }
            }
            let pausedNow = pauseRequested && wasStopped
            pauseRequested = false
            if pausedNow, let i = current.messages.firstIndex(where: { $0.id == replyID }) {
                current.messages[i].notice = "Paused while iFuck AI was in the background. It continues when you come back."
                paused = (current.id, replyID, weights)
            }
            apply(persist: true)
            generatingChat = nil
            if pausedNow {
                if isActive, let p = paused { resume(p) }
            } else if !isActive, let reply = current.messages.first(where: { $0.id == replyID }) {
                notifyFinished(chat: current, reply: reply)
            }
            endBackgroundTask()
        }
    }

    func requestNotificationsIfNeeded() {
        guard settings.notifications, !askedForNotifications, !isGenerating else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyFinished(chat: Chat, reply: Message) {
        guard settings.notifications else { return }
        let answer = Thinking.split(reply.text).answer
        post(title: chat.title, body: answer.isEmpty ? "Your reply is ready." : String(answer.prefix(180)), chatID: chat.id)
    }

    private func notifyPaused() {
        guard settings.notifications, let id = paused?.chatID ?? generatingChat, let chat = chats.chat(id) else { return }
        post(title: chat.title, body: "Reply paused. Open iFuck AI to finish it, or turn on Background replies in Settings.", chatID: chat.id)
    }

    private func post(title: String, body: String, chatID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["chatID": chatID.uuidString]
        let request = UNNotificationRequest(identifier: chatID.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "reply") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pauseRequested = true
                self.engine.stop()
                self.notifyPaused()
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func image(for attachment: Attachment) -> EngineImage? {
        if let cached = imageCache[attachment.id] { return cached }
        let image = Media.engineImage(attachment)
        imageCache[attachment.id] = image
        return image
    }

    private static let systemID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

extension Notification.Name {
    static let openChat = Notification.Name("openChat")
}
