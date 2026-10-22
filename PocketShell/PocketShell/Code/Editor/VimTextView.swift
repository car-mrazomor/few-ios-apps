import Runestone
import UIKit

/// Runestone TextView with hardware-keyboard shortcuts routed to vim, and a vim key bar above the keyboard.
final class VimTextView: TextView {
    /// True while vim (or the key bar) edits the text itself, so the delegate doesn't treat it as typing.
    var isApplyingEdit = false
    var onKey: ((String) -> Void)?
    var onSave: (() -> Void)?
    var onRun: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(keyEscape))
        escape.wantsPriorityOverSystemBehavior = true
        let controlBracket = UIKeyCommand(input: "[", modifierFlags: .control, action: #selector(keyEscape))
        return [
            escape,
            controlBracket,
            UIKeyCommand(input: "r", modifierFlags: .control, action: #selector(keyRedo)),
            UIKeyCommand(input: "d", modifierFlags: .control, action: #selector(keyHalfDown)),
            UIKeyCommand(input: "u", modifierFlags: .control, action: #selector(keyHalfUp)),
            UIKeyCommand(title: "Save", action: #selector(keySave), input: "s", modifierFlags: .command),
            UIKeyCommand(title: "Run", action: #selector(keyRun), input: "r", modifierFlags: .command),
        ] + (super.keyCommands ?? [])
    }

    /// Replaces text on behalf of the app rather than the keyboard.
    func applyEdit(_ range: NSRange, with text: String) {
        isApplyingEdit = true
        replace(range, withText: text)
        isApplyingEdit = false
    }

    @objc private func keyEscape() { onKey?("<Esc>") }
    @objc private func keyRedo() { onKey?("<C-r>") }
    @objc private func keyHalfDown() { onKey?("<C-d>") }
    @objc private func keyHalfUp() { onKey?("<C-u>") }
    @objc private func keySave() { onSave?() }
    @objc private func keyRun() { onRun?() }
}

/// One-row key bar for the editor: Esc pinned left, vim-friendly keys scrolling, hide-keyboard pinned right.
final class EditorKeyBar: UIInputView {
    private let onKey: (String) -> Void
    private let onPaste: () -> Void
    private let onHide: () -> Void

    init(onKey: @escaping (String) -> Void, onPaste: @escaping () -> Void, onHide: @escaping () -> Void) {
        self.onKey = onKey
        self.onPaste = onPaste
        self.onHide = onHide
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    private func build() {
        let escape = button("esc", key: "<Esc>", width: 52, accent: true)
        let keys: [(String, String)] = [
            (":", ":"), ("/", "/"), ("←", "<Left>"), ("↓", "<Down>"), ("↑", "<Up>"), ("→", "<Right>"),
            ("undo", "<Undo>"), ("redo", "<C-r>"), ("tab", "<Tab>"),
            ("(", "("), (")", ")"), ("[", "["), ("]", "]"), ("{", "{"), ("}", "}"),
            ("\"", "\""), ("'", "'"), ("_", "_"), ("=", "="), ("#", "#"), ("<", "<"), (">", ">"),
            ("$", "$"), ("0", "0"), ("^", "^"), ("%", "%"), ("*", "*"), ("|", "|"), ("\\", "\\"), ("`", "`"), ("~", "~"),
        ]
        let scrollStack = UIStackView(arrangedSubviews: keys.map { title, key in
            button(title, key: key, width: title.count > 1 ? 50 : 36)
        })
        scrollStack.spacing = 5
        scrollStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.addSubview(scrollStack)
        NSLayoutConstraint.activate([
            scrollStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            scrollStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scrollStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            scrollStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            scrollStack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        let paste = symbolButton("doc.on.clipboard") { [unowned self] in onPaste() }
        let hide = symbolButton("keyboard.chevron.compact.down") { [unowned self] in onHide() }
        let row = UIStackView(arrangedSubviews: [escape, scroll, paste, hide])
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    private func button(_ title: String, key: String, width: CGFloat, accent: Bool = false) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = accent ? Gruvbox.yellow.withAlphaComponent(0.9) : Gruvbox.bg2
        config.baseForegroundColor = accent ? Gruvbox.bg0 : Gruvbox.fg
        config.cornerStyle = .medium
        config.contentInsets = .zero
        var attributes = AttributeContainer()
        attributes.font = title.count > 1
            ? UIFont.systemFont(ofSize: 13, weight: .semibold)
            : UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        config.attributedTitle = AttributedString(title, attributes: attributes)
        let button = UIButton(configuration: config, primaryAction: UIAction { [unowned self] _ in
            UIDevice.current.playInputClick()
            onKey(key)
        })
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    private func symbolButton(_ symbol: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Gruvbox.bg2
        config.baseForegroundColor = Gruvbox.fg
        config.cornerStyle = .medium
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return button
    }
}

extension EditorKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
