import SwiftTerm
import SwiftUI
import UIKit

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    /// Highlight for active modifier keys and the tab strip.
    let accent: String
    let isDark: Bool
    /// ANSI 0–15: black, red, green, yellow, blue, magenta, cyan, white, then bright variants.
    let ansi: [String]

    static func == (a: Theme, b: Theme) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var backgroundColor: UIColor { UIColor(hex: background) }
    var foregroundColor: UIColor { UIColor(hex: foreground) }
    var accentColor: UIColor { UIColor(hex: accent) }

    var terminalPalette: [SwiftTerm.Color] {
        ansi.map { hex in
            let (r, g, b) = UIColor.rgb(hex)
            return SwiftTerm.Color(red8: UInt16(r), green8: UInt16(g), blue8: UInt16(b))
        }
    }

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? all[0]
    }
}

extension Theme {
    private static let vivid = [
        "000000", "E5534B", "57C454", "D9B72B", "4D8EF7", "C46FE0", "3FC1C9", "D0D0D0",
        "6E6E6E", "FF6E67", "77E074", "F2D54C", "74A9FF", "DC91F5", "64DDE4", "FFFFFF",
    ]

    static let all: [Theme] = [
        Theme(id: "black", name: "Pure Black", background: "000000", foreground: "E6E6E6",
              cursor: "FFFFFF", selection: "3A3A3A", accent: "0A84FF", isDark: true, ansi: vivid),
        Theme(id: "graphite", name: "Graphite", background: "2A2A2D", foreground: "DCDCDC",
              cursor: "F5F5F5", selection: "4A4A50", accent: "9A9AA2", isDark: true, ansi: vivid),
        Theme(id: "crimson", name: "Crimson", background: "1A0507", foreground: "F4DADA",
              cursor: "FF4D5A", selection: "4D1419", accent: "E5283A", isDark: true,
              ansi: ["1A0507", "FF4D5A", "7FD17A", "F2C14E", "6F9CEB", "E07AB8", "6CCFC9", "E8CFCF",
                     "6B3A3E", "FF7A84", "A3E89F", "FFD77A", "97B9F5", "F2A3D2", "97E5E0", "FFFFFF"]),
        Theme(id: "ocean", name: "Ocean", background: "0B1A2B", foreground: "CFE3F7",
              cursor: "5AC8FA", selection: "1E3A5C", accent: "2F8FEA", isDark: true, ansi: vivid),
        Theme(id: "matrix", name: "Matrix", background: "000A00", foreground: "33FF66",
              cursor: "33FF66", selection: "0F3D1A", accent: "1DB954", isDark: true,
              ansi: ["000A00", "4FD66A", "33FF66", "A8FF60", "2FB34F", "6FE08A", "7DFFA1", "B8FFC8",
                     "1F5C2E", "6BFF8A", "66FF8F", "C8FF8A", "45D168", "8AF5A4", "A0FFBC", "E0FFE8"]),
        Theme(id: "amber", name: "Amber", background: "120B00", foreground: "FFB000",
              cursor: "FFB000", selection: "4A3300", accent: "FF9500", isDark: true,
              ansi: ["120B00", "FF8A3D", "FFC34D", "FFD27A", "E09B00", "FFA347", "FFC966", "FFDDA0",
                     "5C4100", "FFA366", "FFD27A", "FFE3A3", "FFB833", "FFBF80", "FFDB99", "FFF2D9"]),
        Theme(id: "purple", name: "Midnight Purple", background: "140F24", foreground: "E4DCFF",
              cursor: "B48CFF", selection: "352A5C", accent: "9B6BFF", isDark: true, ansi: vivid),
        Theme(id: "dracula", name: "Dracula", background: "282A36", foreground: "F8F8F2",
              cursor: "F8F8F2", selection: "44475A", accent: "BD93F9", isDark: true,
              ansi: ["21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2",
                     "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"]),
        Theme(id: "solarized", name: "Solarized Dark", background: "002B36", foreground: "93A1A1",
              cursor: "93A1A1", selection: "073642", accent: "268BD2", isDark: true,
              ansi: ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5",
                     "586E75", "CB4B16", "93A1A1", "839496", "657B83", "6C71C4", "93A1A1", "FDF6E3"]),
        Theme(id: "nord", name: "Nord", background: "2E3440", foreground: "D8DEE9",
              cursor: "D8DEE9", selection: "434C5E", accent: "88C0D0", isDark: true,
              ansi: ["3B4252", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "E5E9F0",
                     "4C566A", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "8FBCBB", "ECEFF4"]),
        Theme(id: "paper", name: "Paper", background: "FAFAF7", foreground: "1F1F1F",
              cursor: "1F1F1F", selection: "CFE2FF", accent: "007AFF", isDark: false,
              ansi: ["1F1F1F", "C4271F", "2E8B26", "9A6F00", "1F5FCC", "9A3FB5", "11808A", "BFBFBF",
                     "5C5C5C", "E0443B", "3DA834", "B88800", "3D7BF0", "B65AD1", "1B9DA8", "FFFFFF"]),
    ]
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
