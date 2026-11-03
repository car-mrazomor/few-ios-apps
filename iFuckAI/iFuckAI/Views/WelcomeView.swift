import SwiftUI

struct Greeting: View {
    let name: String
    var size: CGFloat = 34
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            (Text("Fuck you, ") + Text(displayName).foregroundColor(theme.accent) + Text("!"))
                .font(.system(size: size, weight: .heavy, design: theme.fontDesign))
                .multilineTextAlignment(.center)
            Text("So rude, but who cares.")
                .font(.system(size: size * 0.47, weight: .medium, design: theme.fontDesign))
                .foregroundStyle(theme.secondary)
        }
    }

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "User" : trimmed
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var app: AppModel
    @Environment(\.theme) private var theme
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)
                Logo(size: 150)
                Greeting(name: settings.userName)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What should I call you?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.secondary)
                    TextField("User", text: $settings.userName)
                        .focused($nameFocused)
                        .textContentType(.givenName)
                        .submitLabel(.done)
                        .padding(14)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.border))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick a look")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.secondary)
                    ThemePicker()
                }
                Button {
                    nameFocused = false
                    withAnimation { settings.onboarded = true }
                    app.requestNotificationsIfNeeded()
                } label: {
                    Text("Let's go")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(theme.onAccent)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.radius))
                }
                Text("Everything runs on your phone. Nothing leaves it.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background.ignoresSafeArea())
    }
}

struct ThemePicker: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.theme) private var theme

    private var options: [(id: String, name: String, colors: [Color])] {
        [(Theme.automatic, "Auto", [Theme.light.background, Theme.dark.background, Theme.dark.text, Theme.dark.accent])]
            + Theme.all.map { ($0.id, $0.name, $0.swatch) }
    }

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(options, id: \.id) { option in
                let selected = settings.theme == option.id
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { settings.theme = option.id }
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 0) {
                            ForEach(Array(option.colors.enumerated()), id: \.offset) { _, color in color }
                        }
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? theme.accent : theme.border, lineWidth: selected ? 3 : 1)
                        )
                        Text(option.name)
                            .font(.caption2.weight(selected ? .bold : .regular))
                            .foregroundStyle(selected ? theme.accent : theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.name) theme")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
