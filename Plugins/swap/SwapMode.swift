import AppKit
import PluginKit

/// Interactive swap mode: every tiled window gets a ring, the arrows walk the
/// selection across them, and Return trades the selected window's slot with the
/// one you started on.
///
/// The rings are borderless panels rather than one full-screen overlay. A
/// full-screen overlay would have to be transparent to clicks *and* opaque to
/// keys, and would cover other displays' windows; per-window panels sit exactly
/// where their window is and cost nothing to position, since the layout has
/// already worked out where that is.
///
/// The selection ring doubles as the keyboard surface — it is the one panel that
/// takes key focus, so there is no separate invisible window to keep in sync.
@MainActor
final class SwapMode {

    private let host: any PluginHost

    private var rings: [CGWindowID: RingPanel] = [:]
    private var candidates: [PluginTiledWindow] = []
    /// The window the swap is anchored on — the one focused when mode started.
    private var origin: CGWindowID?
    private var selected: CGWindowID?
    /// Set while key status is deliberately handed between rings, so the resign
    /// that causes is not mistaken for the user clicking away.
    private var movingSelection = false

    init(host: any PluginHost) {
        self.host = host
    }

    var isActive: Bool { !rings.isEmpty }

    func toggle() {
        isActive ? cancel() : show()
    }

    /// Capture the layout *before* the rings appear: showing them changes which
    /// window is focused, so asking afterwards would report a ring as the
    /// focused window.
    private func show() {
        let state = host.swapState()
        guard let focused = state.focused, state.candidates.count >= 2 else {
            host.note("Swap needs at least two tiled windows")
            return
        }

        candidates = state.candidates
        origin = focused
        selected = focused

        for candidate in candidates {
            let ring = RingPanel(frame: candidate.frame,
                                 label: candidate.appName,
                                 palette: host.palette)
            ring.onKey = { [weak self] key in self?.handle(key) }
            rings[candidate.id] = ring
            ring.orderFront(nil)
        }
        updateRings()

        // The selection ring takes key focus, which is what routes arrows here
        // instead of to the app underneath.
        rings[focused]?.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        for ring in rings.values { ring.orderOut(nil) }
        rings.removeAll()
        candidates = []
        origin = nil
        selected = nil
    }

    // MARK: - Keys

    enum Key {
        case move(PluginDirection)
        case commit
        case cancel
    }

    private func handle(_ key: Key) {
        // Ignore everything while the selection is mid-transfer.
        guard !movingSelection else { return }

        switch key {
        case .cancel:
            cancel()

        case .move(let direction):
            guard let current = selected,
                  let next = host.tiledNeighbor(of: current, direction: direction),
                  rings[next] != nil else { return }
            selected = next
            updateRings()
            // Handing key status to the next ring makes the current one resign,
            // which otherwise reads as "the user clicked away" and cancels the
            // mode on the first arrow press.
            movingSelection = true
            rings[next]?.makeKeyAndOrderFront(nil)
            movingSelection = false

        case .commit:
            guard let origin, let selected, origin != selected else {
                cancel()
                return
            }
            // Tear the rings down first: the swap re-tiles and re-focuses, and
            // leaving panels up over moving windows looks like a stuck overlay.
            cancel()
            host.swapWindows(origin, selected)
        }
    }

    /// The origin wears a muted ring, the selection an accent one, so it is
    /// always clear which two windows Return would exchange.
    private func updateRings() {
        for (id, ring) in rings {
            if id == selected {
                ring.style(color: host.palette.nsColor(.accent), width: 4, showsLabel: true)
            } else if id == origin {
                ring.style(color: host.palette.nsColor(.good), width: 3, showsLabel: false)
            } else {
                ring.style(color: host.palette.nsColor(.muted), width: 2, showsLabel: false)
            }
        }
    }
}

/// One window's highlight ring.
private final class RingPanel: NSPanel {

    var onKey: ((SwapMode.Key) -> Void)?

    private let border = NSBox()
    private let label = NSTextField(labelWithString: "")

    init(frame: CGRect, label appName: String, palette: PluginPalette) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        // Present wherever the user is, and over full-screen apps, since the
        // windows being swapped may be either.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true

        border.boxType = .custom
        border.fillColor = .clear
        border.cornerRadius = 8
        border.titlePosition = .noTitle
        border.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(border)

        label.stringValue = appName
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = palette.nsColor(.background)
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: content.topAnchor),
            border.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            border.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 26),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])

        contentView = content
    }

    /// The selection ring must take key focus — it is the mode's only keyboard
    /// surface — which a panel refuses to do unless it says so.
    override var canBecomeKey: Bool { true }

    func style(color: NSColor, width: CGFloat, showsLabel: Bool) {
        border.borderColor = color
        border.borderWidth = width
        label.isHidden = !showsLabel
        label.layer?.backgroundColor = color.cgColor
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onKey?(.move(.left))
        case 124: onKey?(.move(.right))
        case 125: onKey?(.move(.down))
        case 126: onKey?(.move(.up))
        case 36, 76: onKey?(.commit)      // Return, Enter
        case 53: onKey?(.cancel)          // Escape
        default:
            // Anything else leaves swap mode rather than being swallowed: a
            // half-dismissed overlay that eats keystrokes is far worse than one
            // that gets out of the way.
            onKey?(.cancel)
        }
    }

    /// Losing key status means the user clicked elsewhere; treat that as cancel
    /// rather than leaving rings floating over windows nobody is swapping.
    override func resignKey() {
        super.resignKey()
        onKey?(.cancel)
    }
}
