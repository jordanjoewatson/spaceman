import AppKit
import PluginKit

/// The command palette: a chromeless, key-capable panel with a search field and
/// a result list. Results come from pluggable providers (arithmetic, apps,
/// windows, WM commands), queried in order.
///
/// Ported from the Go version's Gio launcher (`internal/plugins/launcher`).
/// The panel follows the bars' look — frosted system chrome rather than a fixed
/// palette — and dismisses when it loses key status, as Spotlight does.
@MainActor
final class Launcher: NSObject {

    private let providers: [any LauncherProvider]
    /// Palette lookup, so the panel follows the theme selected in Settings
    /// instead of being the one surface that ignores it.
    private let palette: (PluginColorRole) -> NSColor

    /// Fired with the title of whatever the user picked, so usage can be
    /// recorded for ranking.
    var onChoose: ((String) -> Void)?

    private var panel: LauncherPanel?
    private let field = NSTextField()
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "no results")

    private var results: [LauncherResult] = []
    private var selected = 0

    /// How many results to show. A closure so Settings changes apply live.
    var resultLimit: () -> Int = { 8 }

    init(providers: [any LauncherProvider],
         palette: @escaping (PluginColorRole) -> NSColor) {
        self.providers = providers
        self.palette = palette
        super.init()
        field.delegate = self
    }

    // MARK: - Visibility

    /// Shows the launcher if hidden, hides it if shown. Safe from the hotkey.
    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        let panel = ensurePanel()
        for provider in providers { provider.prepareForShow() }

        field.stringValue = ""
        selected = 0
        recompute("")

        // Open centered on the display the pointer is on — that's the one the
        // user is looking at.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: area.midX - panel.frame.width / 2,
                                         y: area.midY - panel.frame.height / 2))
        }

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: - Results

    private func recompute(_ q: String) {
        var all: [LauncherResult] = []
        for provider in providers { all.append(contentsOf: provider.query(q)) }
        // Read through a closure rather than copied at construction, so the
        // Settings stepper takes effect on the next keystroke instead of the
        // next launch.
        results = Array(all.prefix(max(resultLimit(), 1)))
        if selected >= results.count { selected = 0 }
        rebuildRows()
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
        rebuildRows()
    }

    private func activate() {
        guard results.indices.contains(selected) else { return }
        let chosen = results[selected]
        hide()
        onChoose?(chosen.title)
        chosen.action()
    }

    // MARK: - View construction

    private func ensurePanel() -> LauncherPanel {
        if let panel { return panel }
        let panel = LauncherPanel(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Same height as the bars: above ordinary windows, below the menu bar.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        // A summoned palette opens on the Space it was summoned on.
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        let prompt = NSTextField(labelWithString: "›")
        prompt.font = .systemFont(ofSize: 24, weight: .bold)
        prompt.textColor = palette(.accent)

        field.font = .systemFont(ofSize: 22)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search apps, windows, commands…"
        field.lineBreakMode = .byTruncatingTail
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        let header = NSStackView(views: [prompt, field])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 10

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = palette(.muted)
        emptyLabel.isHidden = true

        for subview in [header, scrollView, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        self.panel = panel
        return panel
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        emptyLabel.isHidden = !results.isEmpty
        scrollView.isHidden = results.isEmpty

        for (index, result) in results.enumerated() {
            let row = makeRow(result, selected: index == selected)
            // Add before constraining: activating a constraint to a view that
            // isn't in the hierarchy yet throws (uncatchably).
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Keep the selected row on screen while arrowing through a long list.
        if results.indices.contains(selected), stack.arrangedSubviews.indices.contains(selected) {
            panel?.contentView?.layoutSubtreeIfNeeded()
            let row = stack.arrangedSubviews[selected]
            row.scrollToVisible(row.bounds)
        }
    }

    private func makeRow(_ result: LauncherResult, selected: Bool) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true

        if selected {
            row.layer?.backgroundColor = palette(.accent).withAlphaComponent(0.18).cgColor
            // Accent bar down the left edge of the selected row.
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = palette(.accent).cgColor
            bar.layer?.cornerRadius = 2
            row.addSubview(bar)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                bar.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
                bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
                bar.widthAnchor.constraint(equalToConstant: 3),
            ])
        }

        let title = NSTextField(labelWithString: result.title)
        title.font = .systemFont(ofSize: 14)
        title.textColor = selected ? palette(.accent) : palette(.text)
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: result.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = palette(.muted)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.isHidden = result.subtitle.isEmpty

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        row.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
}

/// The panel itself. Borderless windows can't become key by default; a
/// launcher is nothing without its keyboard focus.
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Keyboard

extension Launcher: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        recompute(field.stringValue)
    }

    /// Arrows move the selection, Enter runs it, Escape dismisses — intercepted
    /// here because the field editor otherwise consumes them as editing keys.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown):    moveSelection(1)
        case #selector(NSResponder.moveUp):      moveSelection(-1)
        case #selector(NSResponder.insertNewline): activate()
        case #selector(NSResponder.cancelOperation): hide()
        default: return false
        }
        return true
    }
}

extension Launcher: NSWindowDelegate {
    /// Clicking anywhere else dismisses the palette, as Spotlight does.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
