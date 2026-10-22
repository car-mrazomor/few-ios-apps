import SwiftTerm
import SwiftUI
import UIKit

/// Gruvbox dark (morhetz/gruvbox), matching the Mac's vim/nvim setup. Used by the editor, terminal and app chrome.
enum Gruvbox {
    static let bg0Hard = UIColor(hex: "1d2021")
    static let bg0 = UIColor(hex: "282828")
    static let bg1 = UIColor(hex: "3c3836")
    static let bg2 = UIColor(hex: "504945")
    static let bg3 = UIColor(hex: "665c54")
    static let bg4 = UIColor(hex: "7c6f64")
    static let fg = UIColor(hex: "ebdbb2")
    static let fg2 = UIColor(hex: "d5c4a1")
    static let fg4 = UIColor(hex: "a89984")
    static let gray = UIColor(hex: "928374")
    static let red = UIColor(hex: "fb4934")
    static let green = UIColor(hex: "b8bb26")
    static let yellow = UIColor(hex: "fabd2f")
    static let blue = UIColor(hex: "83a598")
    static let purple = UIColor(hex: "d3869b")
    static let aqua = UIColor(hex: "8ec07c")
    static let orange = UIColor(hex: "fe8019")
}

extension SwiftUI.Color {
    init(_ color: UIColor) { self.init(uiColor: color) }
}

/// Terminal colors. The fields mirror PocketShell's Theme so its terminal view and key bar work unchanged.
struct Theme {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    /// Highlight for active modifier keys.
    let accent: String
    let isDark: Bool
    /// ANSI 0–15: black, red, green, yellow, blue, magenta, cyan, white, then bright variants.
    let ansi: [String]

    var backgroundColor: UIColor { UIColor(hex: background) }
    var foregroundColor: UIColor { UIColor(hex: foreground) }
    var accentColor: UIColor { UIColor(hex: accent) }

    var terminalPalette: [SwiftTerm.Color] {
        ansi.map { hex in
            let (r, g, b) = UIColor.rgb(hex)
            return SwiftTerm.Color(red8: UInt16(r), green8: UInt16(g), blue8: UInt16(b))
        }
    }

    static let gruvbox = Theme(
        background: "282828", foreground: "ebdbb2", cursor: "fabd2f", selection: "504945",
        accent: "d79921", isDark: true,
        ansi: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
               "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]
    )
}

extension UIColor {
    static func rgb(_ hex: String) -> (Int, Int, Int) {
        let value = Int(hex, radix: 16) ?? 0
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    convenience init(hex: String) {
        let (r, g, b) = UIColor.rgb(hex)
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
