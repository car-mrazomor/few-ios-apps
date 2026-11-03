import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var settings: AppSettings

    @State private var importing = false
    @State private var projectorTarget: LocalModel?
    @State private var cardRepo: String?

    private static let gguf = UTType(filenameExtension: "gguf") ?? .data

    var body: some View {
        NavigationStack {
            List {
                Group {
                if let model = app.loaded, let info = app.loadedInfo {
                    Section("Running now") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.title).font(.headline)
                                Spacer()
                                Button("Unload") { Task { await app.unload() } }
                                    .buttonStyle(.bordered)
                                    .disabled(app.isGenerating)
                            }
                            Text(info.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Chip(text: Format.parameters(info.parameters) + " params")
                                Chip(text: Format.bytes(Int64(info.sizeBytes)))
                                Chip(text: "\(Format.count(info.contextLength)) ctx")
                                if info.vision { Chip(text: "Vision", systemImage: "eye", color: .purple) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !downloads.jobs.isEmpty {
                    Section("Downloading") {
                        ForEach(downloads.jobs) { DownloadRow(job: $0) }
                    }
                }
                Section {
                    ForEach(library.models) { model in
                        LocalModelRow(model: model)
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await app.delete(model) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                if !model.hasVision {
                                    Button {
                                        projectorTarget = model
                                    } label: {
                                        Label("Add Vision Projector…", systemImage: "eye")
                                    }
                                }
                                if let repo = model.repo {
                                    Button {
                                        cardRepo = repo
                                    } label: {
                                        Label("Model Card", systemImage: "doc.text.magnifyingglass")
                                    }
                                }
                                if let repo = model.repo, let url = URL(string: "https://huggingface.co/\(repo)") {
                                    Link(destination: url) { Label("Open on Hugging Face", systemImage: "safari") }
                                }
                                Button(role: .destructive) {
                                    Task { await app.delete(model) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("On this iPhone")
                } footer: {
                    Text("\(Format.bytes(library.totalBytes)) used · \(Format.bytes(Paths.freeDiskBytes)) free")
                }
                }
                .themedRow()
            }
            .themedList()
            .overlay {
                if library.models.isEmpty && downloads.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No models yet", systemImage: "shippingbox")
                    } description: {
                        Text("Download a model from Discover, or import a .gguf file.")
                    } actions: {
                        Button("Discover Models") { app.tab = .discover }
                            .buttonStyle(.borderedProminent)
                        Button("Import File") { importing = true }
                    }
                }
            }
            .navigationTitle("My Models")
            .sheet(isPresented: Binding(get: { cardRepo != nil }, set: { if !$0 { cardRepo = nil } })) {
                if let repo = cardRepo {
                    NavigationStack { ModelCardView(repo: repo) }
                        .modifier(ThemedRoot())
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [Self.gguf, .data]) { result in
                guard case .success(let url) = result else { return }
                do {
                    _ = try library.importModel(from: url)
                } catch {
                    app.alert = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: Binding(get: { projectorTarget != nil }, set: { if !$0 { projectorTarget = nil } }),
                          allowedContentTypes: [Self.gguf, .data]) { result in
                guard case .success(let url) = result, let model = projectorTarget else { return }
                do {
                    try library.attachProjector(to: model, from: url)
                } catch {
                    app.alert = "That file is not a vision projector (mmproj) GGUF."
                }
            }
        }
    }
}

struct LocalModelRow: View {
    let model: LocalModel

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let report = Fit.evaluate(weights: model.sizeBytes, projector: model.projectorBytes, info: model.info, context: settings.contextLength)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let repo = model.repo {
                    Text(repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Chip(text: Format.bytes(model.sizeBytes + model.projectorBytes))
                    if let arch = model.info?.architecture { Chip(text: arch) }
                    if model.hasVision { Chip(text: "Vision", systemImage: "eye", color: .purple) }
                }
                FitBadge(report: report)
            }
            Spacer()
            if app.loaded?.id == model.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            } else if app.loadingID == model.id {
                ProgressView()
            } else {
                Button("Load") {
                    Task {
                        await app.load(model)
                        if app.loaded?.id == model.id {
                            if app.chatPath.isEmpty { app.chatPath = [app.newChat()] }
                            app.tab = .chat
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(app.loadingID != nil || app.isGenerating)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DownloadRow: View {
    let job: DownloadJob
    @EnvironmentObject private var downloads: Downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((job.name as NSString).lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(job.repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if job.error != nil {
                    Button { downloads.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                Button(role: .destructive) { downloads.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            let fraction = downloads.progress[job.id] ?? 0
            ProgressView(value: fraction)
            HStack {
                Text("\(Format.bytes(Int64(Double(job.total) * fraction))) of \(Format.bytes(job.total))")
                Spacer()
                Text("\(Int(fraction * 100))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let error = job.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
