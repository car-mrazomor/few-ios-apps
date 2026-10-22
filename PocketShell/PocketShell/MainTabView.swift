import SwiftUI

/// The dock: PocketShell's server list, then the Code tabs (files, editor, local Python shell).
/// Each side keeps its own look: Servers follows PocketShell's styling, the Code tabs use gruvbox.
struct MainTabView: View {
    @Environment(CodeModel.self) private var code

    private var isCodeTab: Bool { code.tab != .servers }

    var body: some View {
        @Bindable var code = code
        TabView(selection: $code.tab) {
            HostListView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(CodeModel.Tab.servers)
            FilesView()
                .codeTab()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(CodeModel.Tab.files)
            EditorScreen()
                .codeTab()
                .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(CodeModel.Tab.editor)
            TerminalScreen()
                .codeTab()
                .tabItem { Label("Code", systemImage: "terminal") }
                .tag(CodeModel.Tab.terminal)
        }
        // Gruvbox chrome only while a Code tab is showing; the Servers tab looks exactly as before.
        .tint(isCodeTab ? Color(Gruvbox.yellow) : nil)
        .preferredColorScheme(isCodeTab ? .dark : nil)
    }
}

private struct CodeTabStyle: ViewModifier {
    @Environment(CodeModel.self) private var code

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .tint(Color(Gruvbox.yellow))
            .onAppear { code.activate() }
    }
}

private extension View {
    func codeTab() -> some View { modifier(CodeTabStyle()) }
}
