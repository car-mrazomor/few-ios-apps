import Foundation

struct Attachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case image, document }

    let id: UUID
    let kind: Kind
    let name: String
    var file: String?
    var text: String?
    var truncated = false

    var fileURL: URL? { file.map { Paths.attachments.appendingPathComponent($0) } }
}

struct Message: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant }

    let id: UUID
    var role: Role
    var text: String
    var attachments: [Attachment] = []
    var stats: GenerationStats?
    var model: String?
    var notice: String?
    var error: String?
    var status: String?
    var sources: [WebSource]?
    var webContext: String?
    var date = Date()
}

struct Chat: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var messages: [Message]
    var updated: Date

    static func new() -> Chat { Chat(id: UUID(), title: "New chat", messages: [], updated: Date()) }
}

final class ChatStore: ObservableObject {
    @Published private(set) var chats: [Chat] = []

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.chats, includingPropertiesForKeys: nil)) ?? []
        chats = files.compactMap { try? JSONDecoder().decode(Chat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    func chat(_ id: UUID?) -> Chat? { chats.first { $0.id == id } }

    func update(_ chat: Chat, persist: Bool = true) {
        if let i = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[i] = chat
        } else {
            chats.insert(chat, at: 0)
        }
        if persist { save(chat) }
    }

    func save(_ chat: Chat) {
        guard !chat.messages.isEmpty else { return }
        let url = Paths.chats.appendingPathComponent("\(chat.id.uuidString).json")
        if let data = try? JSONEncoder().encode(chat) { try? data.write(to: url, options: .atomic) }
        chats.sort { $0.updated > $1.updated }
    }

    func delete(_ chat: Chat) {
        for attachment in chat.messages.flatMap(\.attachments) {
            if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) }
        }
        try? FileManager.default.removeItem(at: Paths.chats.appendingPathComponent("\(chat.id.uuidString).json"))
        chats.removeAll { $0.id == chat.id }
    }
}
