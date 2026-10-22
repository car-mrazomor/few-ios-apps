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

/// The Code tabs' terminal theme. Not part of `Theme.all`, so PocketShell's theme picker is unchanged.
extension Theme {
    static let gruvbox = Theme(
        id: "gruvbox", name: "Gruvbox", background: "282828", foreground: "ebdbb2", cursor: "fabd2f",
        selection: "504945", accent: "d79921", isDark: true,
        ansi: ["282828", "cc241d", "98971a", "d79921", "458588", "b16286", "689d6a", "a89984",
               "928374", "fb4934", "b8bb26", "fabd2f", "83a598", "d3869b", "8ec07c", "ebdbb2"]
    )
}
