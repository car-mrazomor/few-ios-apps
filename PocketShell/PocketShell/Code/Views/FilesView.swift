import SwiftUI

struct FilesView: View {
    @Environment(CodeModel.self) private var app

    var body: some View {
        NavigationStack {
            FolderView(url: app.workspace, title: "PocketCode")
                .navigationDestination(for: URL.self) { folder in
                    FolderView(url: folder, title: folder.lastPathComponent)
                }
        }
    }
}

private struct Entry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct FolderView: View {
    @Environment(CodeModel.self) private var app
    let url: URL
    let title: String

    @State private var entries: [Entry] = []
    @State private var branch: String?
    @State private var creating: CreateKind?
    @State private var newName = ""
    @State private var renaming: Entry?
    @State private var cloning = false
    @State private var cloneURL = ""
    @State private var error: String?

    private enum CreateKind: Identifiable {
        case file, folder
        var id: Self { self }
    }

    var body: some View {
        List {
            if let branch {
                Label {
                    Text("git: ").foregroundStyle(.secondary) + Text(branch).foregroundStyle(Color(Gruvbox.purple))
                } icon: {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Color(Gruvbox.purple))
                }
                .font(.footnote.monospaced())
                .listRowBackground(Color(Gruvbox.bg1))
            }
            ForEach(entries) { entry in
                row(entry)
                    .listRowBackground(Color(Gruvbox.bg0))
                    .swipeActions {
                        Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                        Button { renaming = entry; newName = entry.name } label: { Label("Rename", systemImage: "pencil") }
                            .tint(Color(Gruvbox.orange))
                    }
                    .contextMenu {
                        if entry.isDirectory {
                            Button { app.runInTerminal("cd \(shellPath(entry.url))") } label: {
                                Label("Open in Terminal", systemImage: "terminal")
                            }
                        } else if entry.url.pathExtension == "py" {
                            Button { app.runInTerminal("run \(shellPath(entry.url))") } label: {
                                Label("Run", systemImage: "play")
                            }
                        }
                        Button { renaming = entry; newName = entry.name } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(Gruvbox.bg0))
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Create a file, or clone a git repository."))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(Gruvbox.bg0Hard), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { newName = "main.py"; creating = .file } label: { Label("New File", systemImage: "doc.badge.plus") }
                    Button { app.newNotebook(in: url) } label: { Label("New Notebook", systemImage: "book.pages") }
                    Button { newName = ""; creating = .folder } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { cloneURL = ""; cloning = true } label: { Label("Clone Repository", systemImage: "arrow.down.circle") }
                    Divider()
                    Button { app.runInTerminal("cd \(shellPath(url))") } label: {
                        Label("Open in Terminal", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                if url == app.workspace {
                    Button { app.showingSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
        }
        .task(id: app.filesRevision) { reload() }
        .refreshable { reload() }
        .alert(creating == .folder ? "New Folder" : "New File", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Clone Repository", isPresented: $cloning) {
            TextField("https://github.com/user/repo.git", text: $cloneURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Clone") {
                let remote = cloneURL.trimmingCharacters(in: .whitespaces)
                guard !remote.isEmpty, let name = URL(string: remote)?.deletingPathExtension().lastPathComponent, !name.isEmpty else { return }
                app.runInTerminal("git clone \(EditorController.quoted(remote)) \(shellPath(url.appending(path: name)))")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("HTTPS URL. For private repos, add a token in Settings first.")
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: Bindable(app).showingSettings) { CodeSettingsView() }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        if entry.isDirectory {
            NavigationLink(value: entry.url) {
                Label {
                    Text(entry.name).foregroundStyle(Color(Gruvbox.fg))
                } icon: {
                    Image(systemName: isRepo(entry.url) ? "folder.badge.gearshape" : "folder.fill")
                        .foregroundStyle(Color(Gruvbox.blue))
                }
            }
        } else {
            Button { app.open(entry.url) } label: {
                HStack {
                    Label {
                        Text(entry.name).foregroundStyle(Color(Gruvbox.fg))
                    } icon: {
                        Image(systemName: icon(for: entry.url)).foregroundStyle(Color(color(for: entry.url)))
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color(Gruvbox.gray))
                }
            }
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "py": "chevron.left.forwardslash.chevron.right"
        case "md", "txt": "doc.text"
        case "ipynb": "book.pages"
        case "json", "yml", "yaml", "toml": "curlybraces"
        case "png", "jpg", "jpeg", "gif": "photo"
        default: "doc"
        }
    }

    private func color(for url: URL) -> UIColor {
        switch url.pathExtension.lowercased() {
        case "py": Gruvbox.green
        case "md", "txt": Gruvbox.fg4
        case "ipynb": Gruvbox.orange
        case "json", "yml", "yaml", "toml": Gruvbox.yellow
        default: Gruvbox.gray
        }
    }

    private func isRepo(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
    }

    private func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        entries = urls
            .filter { $0.lastPathComponent != "__pycache__" }
            // iOS's own folder for files opened from other apps (e.g. AirDropped SSH keys).
            .filter { !($0.lastPathComponent == "Inbox" && url == app.workspace) }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Entry(url: url, isDirectory: values?.isDirectory ?? false, size: values?.fileSize ?? 0)
            }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
        branch = currentBranch()
    }

    private func currentBranch() -> String? {
        var directory = url
        while directory.path.hasPrefix(app.workspace.path) {
            let head = directory.appending(path: ".git/HEAD")
            if let text = try? String(contentsOf: head, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.hasPrefix("ref: refs/heads/") ? String(trimmed.dropFirst(16)) : String(trimmed.prefix(7))
            }
            if directory == app.workspace { break }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") || creating == .folder else { return }
        let target = url.appending(path: name)
        do {
            if creating == .folder {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    error = "\(name) already exists."
                    return
                }
                try Data().write(to: target)
                app.open(target)
            }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rename() {
        guard let entry = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != entry.name else { return }
        do {
            try FileManager.default.moveItem(at: entry.url, to: url.appending(path: name))
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entry: Entry) {
        for document in app.documents where document.url.path.hasPrefix(entry.url.path) {
            app.close(document)
        }
        do {
            try FileManager.default.removeItem(at: entry.url)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
