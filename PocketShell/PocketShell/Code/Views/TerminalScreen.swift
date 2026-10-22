import SwiftUI

struct TerminalScreen: View {
    @Environment(CodeModel.self) private var app

    var body: some View {
        TerminalHost(view: app.terminal.view)
            .padding(.leading, 4)
            .background(Color(Gruvbox.bg0))
            .overlay(alignment: .topTrailing) {
                if case .busy = app.terminal.mode {
                    Button { app.terminal.interrupt() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(Gruvbox.red))
                    .padding(8)
                }
            }
    }
}

private struct TerminalHost: UIViewRepresentable {
    let view: ShellTerminalView

    func makeUIView(context: Context) -> ShellTerminalView {
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: ShellTerminalView, context: Context) {}
}
