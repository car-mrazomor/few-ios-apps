import SwiftUI
import UIKit

struct MessageView: View, Equatable {
    let message: Message
    let streaming: Bool
    @Environment(\.theme) private var theme

    static func == (a: MessageView, b: MessageView) -> Bool {
        a.message == b.message && a.streaming == b.streaming
    }

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistant
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { AttachmentThumbnail(attachment: $0, size: 96) }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(theme.userText)
                        .background(theme.userBubble, in: RoundedRectangle(cornerRadius: theme.radius))
                        .textSelection(.enabled)
                }
                if message.webContext != nil {
                    Label("Searched the web", systemImage: "globe")
                        .font(.caption2)
                        .foregroundStyle(theme.secondary)
                }
            }
        }
    }

    private var assistant: some View {
        let parts = Thinking.split(message.text, streaming: streaming)
        return VStack(alignment: .leading, spacing: 10) {
            if let thinking = parts.thinking, !thinking.isEmpty || parts.open {
                ThinkingView(id: message.id, text: thinking, live: parts.open && streaming)
            }
            if let status = message.status, streaming, parts.answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(theme.secondary)
                }
            } else if parts.answer.isEmpty && streaming && !parts.open {
                TypingDots()
            } else if !parts.answer.isEmpty {
                MarkdownView(parts.answer, selectable: !streaming)
            }
            if let sources = message.sources, !sources.isEmpty {
                SourcesView(sources: sources)
            }
            if let notice = message.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(theme.accent2)
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let stats = message.stats, !streaming {
                Text(footer(stats))
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                UIPasteboard.general.string = parts.answer
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private func footer(_ stats: GenerationStats) -> String {
        var parts = ["\(stats.tokens) tokens", String(format: "%.1f tok/s", stats.tokensPerSecond)]
        if let model = message.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

struct ThinkingView: View {
    let id: UUID
    let text: String
    let live: Bool
    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(live ? "Thinking" : "Thought process")
                    if live { TypingDots(size: 4) }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption)
                }
                .font(.callout)
                .foregroundStyle(theme.accent2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.system(.callout, design: theme.bodyDesign))
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if live && !text.isEmpty {
                Text(String(text.suffix(260)))
                    .font(.system(.caption, design: theme.bodyDesign))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                    .transaction { $0.animation = nil }
            }
        }
        .padding(12)
        .background(theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: min(theme.radius, 12)))
    }
}

struct TypingDots: View {
    var size: CGFloat = 7
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: size * 0.7) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(theme.accent)
                        .frame(width: size, height: size)
                        .opacity(0.35 + 0.65 * max(0, sin((t * 4) - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: max(size, 12))
        .accessibilityLabel("Working")
    }
}

struct SourcesView: View {
    let sources: [WebSource]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(theme.onAccent)
                                    .frame(width: 18, height: 18)
                                    .background(theme.accent, in: Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(source.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(url.host() ?? source.url)
                                        .font(.caption2)
                                        .foregroundStyle(theme.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: 200, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: min(theme.radius, 12)))
                        }
                        .foregroundStyle(theme.text)
                    }
                }
            }
        }
    }
}

enum Thinking {
    static func split(_ raw: String, streaming: Bool = false) -> (thinking: String?, answer: String, open: Bool) {
        let text = streaming ? trimPartialTag(raw) : raw
        if let start = text.range(of: "<think>") {
            let before = text[..<start.lowerBound]
            let after = text[start.upperBound...]
            if let end = after.range(of: "</think>") {
                return (trim(after[..<end.lowerBound]), trim(before + after[end.upperBound...]), false)
            }
            return (trim(after), trim(before), true)
        }
        if let end = text.range(of: "</think>") {
            return (trim(text[..<end.lowerBound]), trim(text[end.upperBound...]), false)
        }
        return (nil, trim(Substring(text)), false)
    }

    static func trimPartialTag(_ text: String) -> String {
        guard let lt = text.lastIndex(of: "<") else { return text }
        let tail = String(text[lt...])
        if tail.count < 8, ["<think>", "</think>"].contains(where: { $0.hasPrefix(tail) && $0 != tail }) {
            return String(text[..<lt])
        }
        return text
    }

    private static func trim<S: StringProtocol>(_ s: S) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
