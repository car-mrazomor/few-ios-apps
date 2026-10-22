import Runestone
import UIKit

/// Gruvbox dark for the editor, mapped from gruvbox.nvim's tree-sitter highlight groups.
final class GruvboxEditorTheme: Runestone.Theme {
    let font: UIFont
    let lineNumberFont: UIFont

    init(fontSize: CGFloat) {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: fontSize * 0.85, weight: .regular)
    }

    let textColor = Gruvbox.fg
    let gutterBackgroundColor = Gruvbox.bg0
    let gutterHairlineColor = Gruvbox.bg0
    let gutterHairlineWidth: CGFloat = 0
    let lineNumberColor = Gruvbox.bg4
    let selectedLineBackgroundColor = Gruvbox.bg1  // cursorline
    let selectedLinesLineNumberColor = Gruvbox.yellow
    let selectedLinesGutterBackgroundColor = Gruvbox.bg1
    let invisibleCharactersColor = Gruvbox.bg2
    let pageGuideHairlineColor = Gruvbox.bg1
    let pageGuideHairlineWidth: CGFloat = 1
    let pageGuideBackgroundColor = Gruvbox.bg0
    let markedTextBackgroundColor = Gruvbox.bg2
    let markedTextBackgroundCornerRadius: CGFloat = 2

    func textColor(for highlightName: String) -> UIColor? {
        // Most specific first: "function.builtin" falls back to "function".
        var name = highlightName
        while true {
            if let color = Self.colors[name] { return color }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = String(name[..<dot])
        }
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        if highlightName.hasPrefix("comment") { return .italic }
        if highlightName.hasPrefix("text.title") || highlightName == "function" { return .bold }
        return []
    }

    private static let colors: [String: UIColor] = [
        "comment": Gruvbox.gray,
        "keyword": Gruvbox.red,
        "conditional": Gruvbox.red,
        "repeat": Gruvbox.red,
        "include": Gruvbox.aqua,
        "string": Gruvbox.green,
        "string.special.key": Gruvbox.blue,
        "escape": Gruvbox.orange,
        "string.escape": Gruvbox.orange,
        "number": Gruvbox.purple,
        "boolean": Gruvbox.purple,
        "constant": Gruvbox.purple,
        "constant.builtin": Gruvbox.purple,
        "function": Gruvbox.green,
        "function.builtin": Gruvbox.yellow,
        "function.method": Gruvbox.green,
        "constructor": Gruvbox.yellow,
        "type": Gruvbox.yellow,
        "property": Gruvbox.blue,
        "field": Gruvbox.blue,
        "variable": Gruvbox.fg,
        "variable.builtin": Gruvbox.orange,
        "operator": Gruvbox.orange,
        "punctuation": Gruvbox.fg4,
        "punctuation.special": Gruvbox.orange,
        "embedded": Gruvbox.aqua,
        "tag": Gruvbox.aqua,
        "attribute": Gruvbox.yellow,
        "text.title": Gruvbox.green,
        "text.literal": Gruvbox.aqua,
        "text.uri": Gruvbox.blue,
        "text.reference": Gruvbox.orange,
        "error": Gruvbox.red,
    ]
}
