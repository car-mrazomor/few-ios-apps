import SwiftUI

struct Curated: Identifiable {
    let id: String
    let blurb: String
    let vision: Bool

    static let list = [
        Curated(id: "unsloth/Qwen3.5-4B-GGUF", blurb: "Smart all-rounder with vision and step-by-step thinking.", vision: true),
        Curated(id: "LiquidAI/LFM2.5-VL-1.6B-GGUF", blurb: "Small and very fast. Great for quick camera questions.", vision: true),
        Curated(id: "Qwen/Qwen3-VL-4B-Instruct-GGUF", blurb: "Strong at reading photos, screenshots and documents.", vision: true),
        Curated(id: "unsloth/Qwen3.5-2B-GGUF", blurb: "Light and fast chat with vision.", vision: true),
        Curated(id: "unsloth/gemma-4-E4B-it-GGUF", blurb: "Google Gemma 4, multimodal. Uses most of an 8 GB iPhone.", vision: true),
        Curated(id: "unsloth/Llama-3.2-3B-Instruct-GGUF", blurb: "Classic text-only assistant from Meta.", vision: false),
    ]
}

struct DiscoverView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var results: [HFModel] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showAll = false

    private var visible: [HFModel] { showAll ? results : results.filter(\.isChat) }

    var body: some View {
        NavigationStack {
            List {
                Group {
                if query.isEmpty {
                    Section {
                        ForEach(Curated.list) { item in
                            NavigationLink(value: item.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.id.split(separator: "/").last.map(String.init) ?? item.id)
                                            .font(.headline)
                                        if item.vision { Chip(text: "Vision", systemImage: "eye", color: .purple) }
                                    }
                                    Text(item.blurb)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text("Recommended for iPhone")
                    }
                }
                Section {
                    if let error {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { model in
                        NavigationLink(value: model.id) { RepoRow(model: model) }
                    }
                    if !loading && visible.isEmpty && error == nil {
                        Text("No GGUF models found.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(query.isEmpty ? "Most downloaded GGUF" : "Results")
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                }
                .themedRow()
            }
            .themedList()
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Search Hugging Face")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Show non-chat models", isOn: $showAll)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .task(id: query) { await search() }
            .refreshable { await search() }
            .navigationDestination(for: String.self) { RepoView(repo: $0) }
        }
    }

    private func search() async {
        if !query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            let found = try await settings.hf.search(query.trimmingCharacters(in: .whitespaces))
            guard !Task.isCancelled else { return }
            results = found
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RepoRow: View {
    let model: HFModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(model.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let downloads = model.downloads {
                    Chip(text: Format.count(downloads), systemImage: "arrow.down")
                }
                if let likes = model.likes, likes > 0 {
                    Chip(text: Format.count(likes), systemImage: "heart")
                }
                if model.isVision { Chip(text: "Vision", systemImage: "eye", color: .purple) }
                if !model.isChat { Chip(text: "Not chat", color: .gray) }
                if model.isGated { Chip(text: "Gated", systemImage: "lock", color: .orange) }
            }
        }
        .opacity(model.isChat ? 1 : 0.6)
    }
}

struct RepoView: View {
    let repo: String

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var app: AppModel

    @State private var model: HFModel?
    @State private var variants: [GGUFVariant] = []
    @State private var projectors: [GGUFVariant] = []
    @State private var info: GGUFInfo?
    @State private var infoError: String?
    @State private var error: String?
    @State private var includeVision = true
    @State private var confirm: GGUFVariant?

    private var projector: GGUFVariant? { includeVision ? GGUFVariant.preferredProjector(projectors) : nil }

    var body: some View {
        List {
            Group {
            header
            compatibility
            if !projectors.isEmpty {
                Section {
                    Toggle(isOn: $includeVision) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Vision", systemImage: "eye")
                            if let p = GGUFVariant.preferredProjector(projectors) {
                                Text("Adds \(Format.bytes(p.size)) so the model can see photos and camera shots.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                if variants.isEmpty && error == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                ForEach(variants) { variant in
                    VariantRow(repo: repo, variant: variant, report: report(variant)) {
                        download(variant)
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Q4_K_M is the usual best balance of quality and size. Estimates assume a \(settings.contextLength)-token context.")
            }
            }
            .themedRow()
        }
        .themedList()
        .navigationTitle(repo.split(separator: "/").last.map(String.init) ?? repo)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("This model probably won't run", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Download Anyway") {
                if let v = confirm { start(v) }
            }
        } message: {
            if let v = confirm { Text(report(v).message) }
        }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(repo)
                    .font(.headline)
                    .textSelection(.enabled)
                if let model {
                    HStack(spacing: 6) {
                        if let d = model.downloads { Chip(text: Format.count(d), systemImage: "arrow.down") }
                        if let l = model.likes { Chip(text: Format.count(l), systemImage: "heart") }
                        if let license = model.cardData?.license { Chip(text: license, systemImage: "doc.plaintext") }
                        if !projectors.isEmpty { Chip(text: "Vision", systemImage: "eye", color: .purple) }
                    }
                    if model.isGated {
                        Label(settings.hfToken.isEmpty ? "Gated: accept the license on huggingface.co and add a token in Settings." : "Gated: make sure you accepted the license on huggingface.co.", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    NavigationLink {
                        ModelCardView(repo: repo)
                    } label: {
                        Label("Details", systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    Link(destination: URL(string: "https://huggingface.co/\(repo)")!) {
                        Label("Hugging Face", systemImage: "safari")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var compatibility: some View {
        Section("Compatibility") {
            if let info {
                let supported = info.architecture.map { Architectures.supported.contains($0) } ?? false
                LabeledContent("Architecture") {
                    HStack(spacing: 4) {
                        Text(info.architecture ?? "unknown")
                        Image(systemName: supported ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(supported ? .green : .red)
                    }
                }
                if let layers = info.blockCount { LabeledContent("Layers", value: "\(layers)") }
                if let ctx = info.contextLength { LabeledContent("Trained context", value: "\(Format.count(ctx)) tokens") }
                if let kv = info.kvCacheBytes(context: min(settings.contextLength, info.contextLength ?? settings.contextLength)) {
                    LabeledContent("Context memory", value: "≈ \(Format.bytes(kv))")
                }
                LabeledContent("Memory available to apps", value: Format.bytes(Fit.memoryBudget))
            } else if let infoError {
                Label(infoError, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            } else if !variants.isEmpty {
                HStack {
                    ProgressView()
                    Text("Reading model header…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func report(_ variant: GGUFVariant) -> FitReport {
        Fit.evaluate(weights: variant.size, projector: projector?.size ?? 0, info: info, context: settings.contextLength, pipeline: model?.pipelineTag)
    }

    private func load() async {
        let client = settings.hf
        async let meta = try? client.model(repo)
        do {
            let groups = GGUFVariant.group(try await client.files(repo))
            variants = groups.models
            projectors = groups.projectors
            if variants.isEmpty { error = "This repository has no GGUF model files." }
        } catch {
            self.error = error.localizedDescription
        }
        model = await meta
        guard let probe = variants.first(where: \.isRecommended) ?? variants.first else { return }
        do {
            info = try await client.ggufInfo(repo: repo, path: probe.primary.path)
        } catch {
            infoError = "Couldn't read the model header. \(error.localizedDescription)"
        }
    }

    private func download(_ variant: GGUFVariant) {
        let r = report(variant)
        if r.level == .tooBig || r.level == .notChat {
            confirm = variant
        } else {
            start(variant)
        }
    }

    private func start(_ variant: GGUFVariant) {
        do {
            try downloads.start(repo: repo, variant: variant, projector: projector, info: info)
        } catch {
            app.alert = error.localizedDescription
        }
    }
}

struct VariantRow: View {
    let repo: String
    let variant: GGUFVariant
    let report: FitReport
    let onDownload: () -> Void

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: Downloads

    private var id: String { "\(repo)/\(variant.id)" }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(variant.quant)
                        .font(.subheadline.weight(.semibold))
                    if variant.isRecommended { Chip(text: "Recommended", color: .blue) }
                    if variant.isSplit { Chip(text: "\(variant.files.count) parts") }
                }
                HStack(spacing: 6) {
                    Text(Format.bytes(variant.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FitBadge(report: report)
                    SpeedLabel(report: report)
                }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var trailing: some View {
        if library.contains(id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
        } else if let job = downloads.job(id) {
            if job.error != nil {
                Button { downloads.retry(id) } label: {
                    Image(systemName: "arrow.clockwise.circle").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry download")
            } else {
                Button { downloads.cancel(id) } label: {
                    ZStack {
                        ProgressView(value: downloads.progress[id] ?? 0)
                            .progressViewStyle(.circular)
                        Image(systemName: "stop.fill").font(.system(size: 8))
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel download")
            }
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(report.level == .unsupported)
            .accessibilityLabel("Download \(variant.quant)")
        }
    }
}
