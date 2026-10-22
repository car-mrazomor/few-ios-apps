import SwiftTerm
import UIKit

/// TerminalView with sticky Ctrl / Alt / Shift driven by the key bar.
/// Tap a modifier once to apply it to the next key; tap again to lock it; a third tap releases it.
final class ShellTerminalView: TerminalView {
    enum Modifier: CaseIterable { case ctrl, alt, shift }
    enum ModifierState { case off, once, locked }

    private(set) var modifiers: [Modifier: ModifierState] = [.ctrl: .off, .alt: .off, .shift: .off]
    var onModifiersChanged: (() -> Void)?
    private var keyBar: KeyBar?

    func installKeyBar(theme: Theme) {
        let bar = KeyBar(terminal: self)
        bar.apply(theme: theme)
        keyBar = bar
        inputAccessoryView = bar
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    func apply(theme: Theme, fontSize: CGFloat) {
        nativeBackgroundColor = theme.backgroundColor
        nativeForegroundColor = theme.foregroundColor
        caretColor = UIColor(hex: theme.cursor)
        selectedTextBackgroundColor = UIColor(hex: theme.selection)
        installColors(theme.terminalPalette)
        keyboardAppearance = theme.isDark ? .dark : .light
        if font.pointSize != fontSize {
            font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        keyBar?.apply(theme: theme)
    }

    // MARK: Modifiers

    func isActive(_ m: Modifier) -> Bool { modifiers[m] != .off }
    func state(of m: Modifier) -> ModifierState { modifiers[m] ?? .off }

    func cycle(_ m: Modifier) {
        switch state(of: m) {
        case .off: modifiers[m] = .once
        case .once: modifiers[m] = .locked
        case .locked: modifiers[m] = .off
        }
        syncSwiftTermModifiers()
    }

    /// Clears one-shot modifiers after a key has used them.
    private func consumeModifiers() {
        for m in Modifier.allCases where modifiers[m] == .once {
            modifiers[m] = .off
        }
        syncSwiftTermModifiers()
    }

    private func syncSwiftTermModifiers() {
        controlModifier = isActive(.ctrl)
        metaModifier = isActive(.alt)
        onModifiersChanged?()
    }

    /// xterm modifier parameter: 1 + shift + 2·alt + 4·ctrl.
    private var modifierCode: Int {
        1 + (isActive(.shift) ? 1 : 0) + (isActive(.alt) ? 2 : 0) + (isActive(.ctrl) ? 4 : 0)
    }

    // MARK: Typed text (software keyboard and symbol keys)

    override func insertText(_ text: String) {
        // SwiftTerm applies Ctrl/Alt itself via controlModifier/metaModifier; Shift is ours.
        super.insertText(isActive(.shift) ? text.uppercased() : text)
        consumeModifiers()
    }

    // MARK: Special keys

    enum SpecialKey {
        case esc, tab, up, down, left, right, home, end, pageUp, pageDown, function(Int)
    }

    func press(_ key: SpecialKey) {
        let m = modifierCode
        let appCursor = getTerminal().applicationCursor
        let csi = "\u{1B}["
        let sequence: String

        func cursor(_ letter: String) -> String {
            m > 1 ? "\(csi)1;\(m)\(letter)" : (appCursor ? "\u{1B}O\(letter)" : "\(csi)\(letter)")
        }
        func tilde(_ code: Int) -> String {
            m > 1 ? "\(csi)\(code);\(m)~" : "\(csi)\(code)~"
        }

        switch key {
        case .esc:
            sequence = "\u{1B}"
        case .tab:
            sequence = isActive(.shift) ? "\(csi)Z" : (isActive(.alt) ? "\u{1B}\t" : "\t")
        case .up: sequence = cursor("A")
        case .down: sequence = cursor("B")
        case .right: sequence = cursor("C")
        case .left: sequence = cursor("D")
        case .home: sequence = cursor("H")
        case .end: sequence = cursor("F")
        case .pageUp: sequence = tilde(5)
        case .pageDown: sequence = tilde(6)
        case .function(let n) where n <= 4:
            let letter = ["P", "Q", "R", "S"][n - 1]
            sequence = m > 1 ? "\(csi)1;\(m)\(letter)" : "\u{1B}O\(letter)"
        case .function(let n):
            let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
            sequence = tilde(codes[n] ?? 15)
        }
        send(Array(sequence.utf8))
        consumeModifiers()
    }

    /// Sends a control character directly (for the ^C / ^D shortcut keys), ignoring sticky modifiers.
    func sendControl(_ letter: Character) {
        guard let ascii = letter.uppercased().first?.asciiValue else { return }
        send([ascii & 0x1F])
    }
}
