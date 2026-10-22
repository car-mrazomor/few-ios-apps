import SwiftUI

@main
struct PocketCodeApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Color(Gruvbox.yellow))
            #if DEBUG
                .onAppear { DebugLaunch.run(app) }
            #endif
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(AppModel.Tab.files)
            EditorScreen()
                .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(AppModel.Tab.editor)
            TerminalScreen()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(AppModel.Tab.terminal)
        }
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = Gruvbox.bg0Hard
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}
