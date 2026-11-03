import SwiftUI

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let scheme: ColorScheme
    let background: Color
    let surface: Color
    let surface2: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let accent2: Color
    let border: Color
    let userBubble: Color
    let userText: Color
    let onAccent: Color
    let fontDesign: Font.Design
    let bodyDesign: Font.Design
    let radius: CGFloat

    init(_ id: String, _ name: String, _ scheme: ColorScheme,
         bg: UInt32, surface: UInt32, surface2: UInt32, text: UInt32, secondary: UInt32,
         accent: UInt32, accent2: UInt32, border: UInt32, bubble: UInt32, bubbleText: UInt32, onAccent: UInt32,
         font: Font.Design = .default, body: Font.Design? = nil, radius: CGFloat = 14) {
        self.id = id
        self.name = name
        self.scheme = scheme
        background = Color(hex: bg)
        self.surface = Color(hex: surface)
        self.surface2 = Color(hex: surface2)
        self.text = Color(hex: text)
        self.secondary = Color(hex: secondary)
        self.accent = Color(hex: accent)
        self.accent2 = Color(hex: accent2)
        self.border = Color(hex: border)
        userBubble = Color(hex: bubble)
        userText = Color(hex: bubbleText)
        self.onAccent = Color(hex: onAccent)
        fontDesign = font
        bodyDesign = body ?? font
        self.radius = radius
    }

    static let dark = Theme("dark", "Dark", .dark,
        bg: 0x000000, surface: 0x141414, surface2: 0x1F1F1F, text: 0xF5F5F5, secondary: 0x9A9A9A,
        accent: 0xFF7A1A, accent2: 0xFFA552, border: 0x2A2A2A, bubble: 0xFF7A1A, bubbleText: 0x000000, onAccent: 0x000000,
        font: .rounded, radius: 18)

    static let light = Theme("light", "Light", .light,
        bg: 0xFFFFFF, surface: 0xFFF4EB, surface2: 0xFFE8D6, text: 0x111111, secondary: 0x6E6259,
        accent: 0xF26A00, accent2: 0xFF9A3C, border: 0xF5D9C2, bubble: 0xF26A00, bubbleText: 0xFFFFFF, onAccent: 0xFFFFFF,
        font: .rounded, radius: 18)

    static let claudeLight = Theme("claude-light", "Claude", .light,
        bg: 0xFAF9F5, surface: 0xF0EEE6, surface2: 0xE8E6DC, text: 0x141413, secondary: 0x73726C,
        accent: 0xD97757, accent2: 0xC6613F, border: 0xE3E0D5, bubble: 0xF0EEE6, bubbleText: 0x141413, onAccent: 0xFFFFFF,
        body: .serif, radius: 16)

    static let claudeDark = Theme("claude-dark", "Claude Dark", .dark,
        bg: 0x262624, surface: 0x30302E, surface2: 0x1F1E1D, text: 0xFAF9F5, secondary: 0xA6A39A,
        accent: 0xD97757, accent2: 0xE08A6D, border: 0x3D3D3A, bubble: 0x141413, bubbleText: 0xFAF9F5, onAccent: 0xFFFFFF,
        body: .serif, radius: 16)

    static let odysseus = Theme("odysseus", "Odysseus", .dark,
        bg: 0x282C34, surface: 0x1E2228, surface2: 0x111111, text: 0x9CDEF2, secondary: 0x6B8A94,
        accent: 0xE06C75, accent2: 0xF0989E, border: 0x355A66, bubble: 0x355A66, bubbleText: 0xB9E6F4, onAccent: 0x111111,
        font: .monospaced, radius: 8)

    static let gruvbox = Theme("gruvbox", "Gruvbox", .dark,
        bg: 0x282828, surface: 0x3C3836, surface2: 0x32302F, text: 0xEBDBB2, secondary: 0xA89984,
        accent: 0xFE8019, accent2: 0xFABD2F, border: 0x504945, bubble: 0x504945, bubbleText: 0xFBF1C7, onAccent: 0x282828,
        font: .monospaced, radius: 6)

    static let gruvboxLight = Theme("gruvbox-light", "Gruvbox Light", .light,
        bg: 0xFBF1C7, surface: 0xF2E5BC, surface2: 0xEBDBB2, text: 0x3C3836, secondary: 0x7C6F64,
        accent: 0xAF3A03, accent2: 0xB57614, border: 0xD5C4A1, bubble: 0xD5C4A1, bubbleText: 0x282828, onAccent: 0xFBF1C7,
        font: .monospaced, radius: 6)

    static let tokyoNight = Theme("tokyo-night", "Tokyo Night", .dark,
        bg: 0x1A1B26, surface: 0x24283B, surface2: 0x16161E, text: 0xC0CAF5, secondary: 0x565F89,
        accent: 0x7AA2F7, accent2: 0xBB9AF7, border: 0x292E42, bubble: 0x3D59A1, bubbleText: 0xC0CAF5, onAccent: 0x1A1B26,
        font: .monospaced, radius: 8)

    static let catppuccin = Theme("catppuccin", "Catppuccin", .dark,
        bg: 0x1E1E2E, surface: 0x313244, surface2: 0x181825, text: 0xCDD6F4, secondary: 0x9399B2,
        accent: 0xCBA6F7, accent2: 0xF5C2E7, border: 0x45475A, bubble: 0x45475A, bubbleText: 0xCDD6F4, onAccent: 0x1E1E2E,
        font: .rounded, radius: 16)

    static let dracula = Theme("dracula", "Dracula", .dark,
        bg: 0x282A36, surface: 0x343746, surface2: 0x21222C, text: 0xF8F8F2, secondary: 0x6272A4,
        accent: 0xFF79C6, accent2: 0xBD93F9, border: 0x44475A, bubble: 0x6272A4, bubbleText: 0xF8F8F2, onAccent: 0x282A36,
        font: .monospaced, radius: 8)

    static let nord = Theme("nord", "Nord", .dark,
        bg: 0x2E3440, surface: 0x3B4252, surface2: 0x434C5E, text: 0xECEFF4, secondary: 0x8D99AE,
        accent: 0x88C0D0, accent2: 0x81A1C1, border: 0x4C566A, bubble: 0x5E81AC, bubbleText: 0xECEFF4, onAccent: 0x2E3440,
        radius: 10)

    static let solarized = Theme("solarized", "Solarized", .dark,
        bg: 0x002B36, surface: 0x073642, surface2: 0x00212B, text: 0x93A1A1, secondary: 0x657B83,
        accent: 0x268BD2, accent2: 0x2AA198, border: 0x0E4B59, bubble: 0x0E4B59, bubbleText: 0xEEE8D5, onAccent: 0xFDF6E3,
        font: .monospaced, radius: 6)

    static let rosePine = Theme("rose-pine", "Rosé Pine", .dark,
        bg: 0x191724, surface: 0x1F1D2E, surface2: 0x26233A, text: 0xE0DEF4, secondary: 0x908CAA,
        accent: 0xEBBCBA, accent2: 0xC4A7E7, border: 0x26233A, bubble: 0x403D52, bubbleText: 0xE0DEF4, onAccent: 0x191724,
        font: .rounded, radius: 14)

    static let all = [dark, light, claudeLight, claudeDark, odysseus, gruvbox, gruvboxLight, tokyoNight, catppuccin, dracula, nord, solarized, rosePine]
    static let automatic = "auto"

    static func resolve(_ id: String, system: ColorScheme) -> Theme {
        if id == automatic { return system == .dark ? dark : light }
        return all.first { $0.id == id } ?? dark
    }

    var swatch: [Color] { [background, surface == background ? surface2 : surface, text, accent] }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct ThemedList: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.background)
    }
}

struct ThemedRow: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.listRowBackground(theme.surface)
    }
}

extension View {
    func themedList() -> some View { modifier(ThemedList()) }
    func themedRow() -> some View { modifier(ThemedRow()) }
}

struct ThemedRoot: ViewModifier {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var system

    func body(content: Content) -> some View {
        let theme = Theme.resolve(settings.theme, system: system)
        content
            .environment(\.theme, theme)
            .tint(theme.accent)
            .foregroundStyle(theme.text)
            .fontDesign(theme.fontDesign)
            .preferredColorScheme(settings.theme == Theme.automatic ? nil : theme.scheme)
            .background(theme.background.ignoresSafeArea())
    }
}

extension View {
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(GlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08)))
        }
    }
}

@available(iOS 26.0, *)
private enum GlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        return interactive ? base.interactive() : base
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct Logo: View {
    var size: CGFloat = 120
    @Environment(\.theme) private var theme

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .shadow(color: theme.accent.opacity(0.55), radius: size * 0.18)
    }
}
