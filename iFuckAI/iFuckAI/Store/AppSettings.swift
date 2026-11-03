import Foundation

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: "systemPrompt") } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: "temperature") } }
    @Published var contextLength: Int { didSet { defaults.set(contextLength, forKey: "contextLength") } }
    @Published var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: "maxTokens") } }
    @Published var hfToken: String { didSet { Keychain.set("hfToken", hfToken) } }
    @Published var theme: String { didSet { defaults.set(theme, forKey: "theme") } }
    @Published var userName: String { didSet { defaults.set(userName, forKey: "userName") } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    @Published var webSearch: Bool { didSet { defaults.set(webSearch, forKey: "webSearch") } }
    @Published var backgroundCPU: Bool { didSet { defaults.set(backgroundCPU, forKey: "backgroundCPU") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }

    static let contextOptions = [2048, 4096, 8192, 16384, 32768]

    init() {
        systemPrompt = defaults.string(forKey: "systemPrompt") ?? "You are a helpful assistant called iFuck AI, running privately on the user's iPhone. You are blunt, witty and genuinely useful."
        temperature = defaults.object(forKey: "temperature") as? Double ?? 0.7
        contextLength = defaults.object(forKey: "contextLength") as? Int ?? 4096
        maxTokens = defaults.object(forKey: "maxTokens") as? Int ?? 2048
        hfToken = Keychain.get("hfToken") ?? ""
        theme = defaults.string(forKey: "theme") ?? Theme.automatic
        userName = defaults.string(forKey: "userName") ?? ""
        onboarded = defaults.bool(forKey: "onboarded")
        webSearch = defaults.bool(forKey: "webSearch")
        backgroundCPU = defaults.bool(forKey: "backgroundCPU")
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
    }

    var engine: EngineSettings {
        var s = EngineSettings()
        s.temperature = Float(temperature)
        s.maxTokens = maxTokens
        return s
    }

    var hf: HFClient { HFClient(token: hfToken) }
}
