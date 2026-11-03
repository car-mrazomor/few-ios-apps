import SwiftUI

struct ModelCard {
    var license: String?
    var baseModels: [String] = []
    var languages: [String] = []
    var tags: [String] = []
    var body: String

    init(_ readme: String) {
        body = ""
        var text = readme
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let yaml = String(text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound])
            text = String(text[end.upperBound...])
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            var key = ""
            for raw in yaml.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if !raw.hasPrefix(" ") && !raw.hasPrefix("-"), let colon = line.firstIndex(of: ":") {
                    key = String(line[..<colon])
                    let value = Self.clean(String(line[line.index(after: colon)...]))
                    if !value.isEmpty { add(key, value) }
                } else if line.hasPrefix("-") {
                    add(key, Self.clean(String(line.dropFirst())))
                }
            }
        }
        body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func add(_ key: String, _ value: String) {
        guard !value.isEmpty, !value.hasPrefix("[") || value.count > 2 else { return }
        let values = value.hasPrefix("[") ? value.dropFirst().dropLast().components(separatedBy: ",").map { Self.clean($0) } : [value]
        switch key {
        case "license": license = values.first
        case "base_model": baseModels += values
        case "language": languages += values
        case "tags": tags += values
        default: break
        }
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}

struct ModelCardView: View {
    let repo: String

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme
    @State private var card: ModelCard?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(repo)
                    .font(.headline)
                    .textSelection(.enabled)
                if let card {
                    meta(card)
                    if card.body.isEmpty {
                        Text("This repository has no description.")
                            .foregroundStyle(theme.secondary)
                    } else {
                        MarkdownView(card.body, stripHTML: true)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(theme.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding()
        }
        .background(theme.background)
        .navigationTitle("Model Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Link(destination: URL(string: "https://huggingface.co/\(repo)")!) {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Open on Hugging Face")
            }
        }
        .task {
            do {
                card = ModelCard(try await settings.hf.readme(repo))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func meta(_ card: ModelCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let license = card.license { Chip(text: license, systemImage: "doc.plaintext") }
                ForEach(card.languages.prefix(4), id: \.self) { Chip(text: $0, systemImage: "globe") }
            }
            ForEach(card.baseModels.filter { $0.contains("/") && $0 != repo }.prefix(3), id: \.self) { base in
                NavigationLink {
                    ModelCardView(repo: base)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Base model")
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                            Text(base)
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(theme.secondary)
                    }
                    .padding(12)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: min(theme.radius, 12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
