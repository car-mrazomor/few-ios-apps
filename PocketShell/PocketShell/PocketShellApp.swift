import SwiftUI

@main
struct PocketShellApp: App {
    @State private var app = AppModel()
    @State private var code = CodeModel()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(app)
                .environment(code)
                .onOpenURL { app.openKeyFile($0) }
            #if DEBUG
                .onAppear {
                    DebugLaunch.run(app)
                    CodeDebugLaunch.run(code)
                }
            #endif
        }
    }
}
