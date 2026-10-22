import UIKit

/// Two-row key bar shown above the keyboard.
/// Row 1: Esc, Tab, Ctrl, Alt, Shift and arrows (always visible).
/// Row 2: scrollable symbols, control shortcuts, navigation and F1–F12, plus paste / hide keyboard.
final class KeyBar: UIInputView {
    private weak var terminal: ShellTerminalView?
    private var modifierButtons: [ShellTerminalView.Modifier: KeyButton] = [:]
    private var allButtons: [KeyButton] = []
    private var accent: UIColor = .systemBlue
    private var repeatTimer: Timer?

    private enum Action {
        case special(ShellTerminalView.SpecialKey)
        case modifier(ShellTerminalView.Modifier)
        case text(String)
        case control(Character)
        case paste, dismissKeyboard
    }

    init(terminal: ShellTerminalView) {
        self.terminal = terminal
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: phone ? 92 : 100), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        terminal.onModifiersChanged = { [weak self] in self?.refreshModifiers() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIDevice.current.userInterfaceIdiom == .phone ? 92 : 100)
    }

    // MARK: Layout

    private func build() {
        let topRow = UIStackView(arrangedSubviews: [
            key("esc", .special(.esc)),
            key("tab", .special(.tab)),
            modifierKey("ctrl", .ctrl),
            modifierKey("alt", .alt),
            modifierKey("⇧", .shift),
            key("←", .special(.left), repeats: true),
            key("↓", .special(.down), repeats: true),
            key("↑", .special(.up), repeats: true),
            key("→", .special(.right), repeats: true),
        ])
        topRow.distribution = .fillEqually
        topRow.spacing = 5

        var scrollKeys: [KeyButton] = ["|", "~", "/", "-", "_", "\\", "`", ":", ";", "'", "\"", "$", "*", "&", "!", "?", "#", "=", "+",
                                       "{", "}", "[", "]", "(", ")", "<", ">", "%", "^", "@"]
            .map { key($0, .text($0), width: 34) }
        scrollKeys += ["C", "D", "Z", "L", "R", "A", "E"].map { key("^\($0)", .control(Character($0)), width: 44) }
        scrollKeys += [
            key("home", .special(.home), width: 54),
            key("end", .special(.end), width: 46),
            key("pgup", .special(.pageUp), width: 52),
            key("pgdn", .special(.pageDown), width: 52),
        ]
        scrollKeys += (1...12).map { key("F\($0)", .special(.function($0)), width: 40) }

        let scrollStack = UIStackView(arrangedSubviews: scrollKeys)
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

        let paste = key("", .paste, width: 40, symbol: "doc.on.clipboard")
        let hide = key("", .dismissKeyboard, width: 40, symbol: "keyboard.chevron.compact.down")
        let bottomRow = UIStackView(arrangedSubviews: [scroll, paste, hide])
        bottomRow.spacing = 5

        let rows = UIStackView(arrangedSubviews: [topRow, bottomRow])
        rows.axis = .vertical
        rows.spacing = 6
        rows.distribution = .fillEqually
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 4),
            rows.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func key(_ title: String, _ action: Action, width: CGFloat? = nil, symbol: String? = nil, repeats: Bool = false) -> KeyButton {
        let button = KeyButton(title: title, symbol: symbol)
        if let width {
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchDown)
        if repeats {
            button.addAction(UIAction { [weak self] _ in self?.startRepeat(action) }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        allButtons.append(button)
        return button
    }

    private func modifierKey(_ title: String, _ modifier: ShellTerminalView.Modifier) -> KeyButton {
        let button = key(title, .modifier(modifier))
        modifierButtons[modifier] = button
        return button
    }

    // MARK: Actions

    private func perform(_ action: Action) {
        guard let terminal else { return }
        UIDevice.current.playInputClick()
        switch action {
        case .special(let key): terminal.press(key)
        case .modifier(let m): terminal.cycle(m)
        case .text(let s): terminal.insertText(s)
        case .control(let c): terminal.sendControl(c)
        case .paste:
            if let text = UIPasteboard.general.string { terminal.send(txt: text) }
        case .dismissKeyboard:
            _ = terminal.resignFirstResponder()
        }
    }

    private func startRepeat(_ action: Action) {
        stopRepeat()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                self?.perform(action)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: Appearance

    func apply(theme: Theme) {
        accent = theme.accentColor
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        refreshModifiers()
    }

    private func refreshModifiers() {
        guard let terminal else { return }
        for (modifier, button) in modifierButtons {
            button.setState(terminal.state(of: modifier), accent: accent)
        }
    }
}

extension KeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

private final class KeyButton: UIButton {
    private let lockBar = UIView()

    init(title: String, symbol: String?) {
        super.init(frame: .zero)
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .secondarySystemFill
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)
        if let symbol {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        } else {
            var attributes = AttributeContainer()
            let isWord = title.count > 2
            attributes.font = isWord
                ? UIFont.systemFont(ofSize: 13, weight: .medium)
                : UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
            config.attributedTitle = AttributedString(title, attributes: attributes)
        }
        configuration = config
        accessibilityLabel = symbol == nil ? title : nil

        lockBar.isHidden = true
        lockBar.isUserInteractionEnabled = false
        lockBar.layer.cornerRadius = 1
        lockBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lockBar)
        NSLayoutConstraint.activate([
            lockBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            lockBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            lockBar.widthAnchor.constraint(equalToConstant: 14),
            lockBar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setState(_ state: ShellTerminalView.ModifierState, accent: UIColor) {
        configuration?.baseBackgroundColor = state == .off ? .secondarySystemFill : accent
        configuration?.baseForegroundColor = state == .off ? .label : .white
        lockBar.backgroundColor = .white
        lockBar.isHidden = state != .locked
    }
}
