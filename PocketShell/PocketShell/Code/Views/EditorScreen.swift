import SwiftUI
import WebKit

struct EditorScreen: View {
    @Environment(CodeModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if let document = app.currentDocument {
                BufferTabs()
                if let editor = document as? EditorController {
                    EditorHost(editor: editor)
                        .id(editor.url)
                    StatusLine(editor: editor)
                } else if let notebook = document as? NotebookController {
                    NotebookHost(notebook: notebook)
                        .id(notebook.url)
                }
            } else {
                ContentUnavailableView {
                    Label("No File Open", systemImage: "chevron.left.forwardslash.chevron.right")
                } description: {
                    Text("Open a file from Files, or run 'vim file.py' in the terminal.")
                } actions: {
                    Button("Browse Files") { app.tab = .files }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(Gruvbox.bg0))
    }
}

/// Open files as tabs (vim buffers) with save and run buttons.
private struct BufferTabs: View {
    @Environment(CodeModel.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(app.documents, id: \.url) { document in
                        let selected = document.url == app.currentDocument?.url
                        HStack(spacing: 5) {
                            Text(document.name + (document.isModified ? " ●" : ""))
                                .font(.footnote.monospaced().weight(selected ? .semibold : .regular))
                                .foregroundStyle(Color(selected ? Gruvbox.fg : Gruvbox.fg4))
                                .lineLimit(1)
                            Button { app.close(document) } label: {
                                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Color(Gruvbox.gray))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(selected ? Gruvbox.bg1 : .clear), in: RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { app.currentDocumentURL = document.url }
                    }
                }
                .padding(.horizontal, 6)
            }
            if let document = app.currentDocument {
                Button { document.save() } label: {
                    Image(systemName: "square.and.arrow.down").frame(width: 34, height: 30)
                }
                .accessibilityLabel("Save")
                if let editor = document as? EditorController, editor.fileType == "python" {
                    Button { editor.run() } label: {
                        Image(systemName: "play.fill").frame(width: 34, height: 30)
                    }
                    .foregroundStyle(Color(Gruvbox.green))
                    .accessibilityLabel("Run")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 6)
        .background(Color(Gruvbox.bg0Hard))
    }
}

private struct NotebookHost: UIViewRepresentable {
    let notebook: NotebookController

    func makeUIView(context: Context) -> WKWebView {
        notebook.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct EditorHost: UIViewRepresentable {
    let editor: EditorController

    func makeUIView(context: Context) -> VimTextView {
        editor.textView
    }

    func updateUIView(_ uiView: VimTextView, context: Context) {}
}

/// vim-airline style status line: mode │ file │ … │ filetype │ position.
private struct StatusLine: View {
    let editor: EditorController

    private var modeColor: UIColor {
        switch editor.modeLabel {
        case "INSERT", "EDIT": Gruvbox.blue
        case "VISUAL", "V-LINE": Gruvbox.orange
        case "COMMAND", "SEARCH": Gruvbox.purple
        default: Gruvbox.fg4
        }
    }

    var body: some View {
        if let commandLine = editor.commandLine {
            Text(commandLine + "▏")
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color(Gruvbox.fg))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Color(Gruvbox.bg0Hard), ignoresSafeAreaEdges: [])
        } else {
            HStack(spacing: 0) {
                segment(editor.modeLabel, fg: Gruvbox.bg0, bg: modeColor, bold: true)
                segment(editor.name + (editor.isModified ? " [+]" : ""), fg: Gruvbox.fg2, bg: Gruvbox.bg2)
                if let message = editor.message {
                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(message.hasPrefix("E") ? Gruvbox.red : Gruvbox.fg4))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
                Spacer(minLength: 4)
                if !editor.pendingKeys.isEmpty {
                    Text(editor.pendingKeys)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(Gruvbox.fg4))
                        .padding(.trailing, 8)
                }
                segment(editor.fileType, fg: Gruvbox.fg4, bg: Gruvbox.bg1)
                segment("\(editor.line):\(editor.column)", fg: Gruvbox.bg0, bg: modeColor, bold: true)
            }
            .frame(height: 26)
            .background(Color(Gruvbox.bg1), ignoresSafeAreaEdges: [])
        }
    }

    private func segment(_ text: String, fg: UIColor, bg: UIColor, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: bold ? .bold : .regular, design: .monospaced))
            .foregroundStyle(Color(fg))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(Color(bg), ignoresSafeAreaEdges: [])
    }
}
