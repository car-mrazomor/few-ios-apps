import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        Form {
            Section("Theme") {
                ForEach(Theme.all) { theme in
                    Button {
                        app.themeID = theme.id
                    } label: {
                        ThemeRow(theme: theme, isSelected: theme.id == app.themeID, fontSize: app.fontSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Stepper(value: $app.fontSize, in: 9...24, step: 1) {
                    LabeledContent("Font Size", value: "\(Int(app.fontSize)) pt")
                }
            } header: {
                Text("Text")
            } footer: {
                Text("Changes apply to open sessions immediately.")
            }
        }
        .navigationTitle("Settings")
    }
}

/// A miniature terminal rendered in the theme's own colors.
struct ThemeRow: View {
    let theme: Theme
    let isSelected: Bool
    var fontSize: Double = 13

    private func color(_ hex: String) -> Color { Color(uiColor: UIColor(hex: hex)) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                (Text("ivan@server").foregroundColor(color(theme.ansi[2]))
                    + Text(":").foregroundColor(color(theme.foreground))
                    + Text("~").foregroundColor(color(theme.ansi[4]))
                    + Text("$ ").foregroundColor(color(theme.foreground))
                    + Text("ls").foregroundColor(color(theme.foreground)))
                (Text("app.log ").foregroundColor(color(theme.foreground))
                    + Text("deploy.sh ").foregroundColor(color(theme.ansi[10]))
                    + Text("src/ ").foregroundColor(color(theme.ansi[12]))
                    + Text("ERR").foregroundColor(color(theme.ansi[1])))
                HStack(spacing: 3) {
                    ForEach(0..<8) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(theme.ansi[i + 8]))
                            .frame(width: 12, height: 6)
                    }
                    Rectangle()
                        .fill(color(theme.cursor))
                        .frame(width: 7, height: 12)
                        .padding(.leading, 4)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(theme.background), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? color(theme.accent) : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
            )

            VStack(alignment: .trailing, spacing: 4) {
                Text(theme.name)
                    .font(.subheadline.weight(.medium))
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? color(theme.accent) : .secondary)
                    .font(.title3)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
