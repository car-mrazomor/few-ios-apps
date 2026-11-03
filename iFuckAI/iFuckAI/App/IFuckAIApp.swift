import SwiftUI
import UserNotifications

@main
struct IFuckAIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.library)
                .environmentObject(app.chats)
                .environmentObject(app.settings)
                .environmentObject(app.downloads)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["chatID"] as? String).flatMap(UUID.init) else { return }
        await MainActor.run { NotificationCenter.default.post(name: .openChat, object: id) }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == Downloads.sessionID {
            Downloads.shared.backgroundCompletion = completionHandler
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if settings.onboarded {
                tabs.id(settings.theme)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .modifier(ThemedRoot())
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
    }

    private var tabs: some View {
        TabView(selection: $app.tab) {
            ChatsView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppModel.Tab.chat)
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkle.magnifyingglass") }
                .tag(AppModel.Tab.discover)
            LibraryView()
                .tabItem { Label("My Models", systemImage: "shippingbox") }
                .tag(AppModel.Tab.models)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .alert("iFuck AI", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alert ?? "")
        }
        .task {
            app.requestNotificationsIfNeeded()
            await app.restoreLastModel()
        }
    }
}
