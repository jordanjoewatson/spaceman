import AppKit
import SwiftUI
import SpacemanCore

/// Owns one top and one bottom bar per screen and keeps them positioned.
///
/// Position is driven entirely by `NSScreen.visibleFrame`, which already
/// excludes the menu bar and Dock — including when either is set to auto-hide.
/// That is the public replacement for the `CGWindowListCopyWindowInfo` probing
/// the Go implementation used: no Screen Recording consent, no private API, and
/// it reacts correctly to display changes, Dock repositioning and notches.
@MainActor
final class BarController {

    private var topBars: [BarWindow] = []
    private var bottomBars: [BarWindow] = []
    private let state: BarState
    private let preferences: Preferences
    /// Bar geometry — height and floating margin — is fixed when a `BarWindow`
    /// is built, so a preset change needs a rebuild. Colours and module content
    /// reach the SwiftUI views through `Preferences` on their own, which is what
    /// keeps dragging a colour picker from tearing down every window.
    private var lastGeometry: BarGeometrySignature
    private var pollTimer: Timer?
    /// One router per bar: a scroll is delivered to the window it landed on, and
    /// that window's zones are the only candidates.
    private var routers: [ObjectIdentifier: ZoneScrollRouter] = [:]
    private var lastVisibleFrames: [CGRect] = []
    /// Reveal state is per display: a pointer at the bottom edge of one screen
    /// hides only that screen's bottom bar.
    private var revealByDisplay: [CGDirectDisplayID: EdgeReveal] = [:]

    /// Bar actions, kept so a display hot-plug can re-run `rebuild`.
    /// `onCycleLayout` carries the display whose bar was clicked — with
    /// separate Spaces per display, each bar drives its own Space's layout.
    private let onCycleLayout: (CGDirectDisplayID) -> Void
    private let onRetile: () -> Void
    private let onShrinkMaster: () -> Void
    private let onGrowMaster: () -> Void

    /// Called when the usable area changes, so the tiler can re-run.
    var onGeometryChange: (() -> Void)?

    init(state: BarState,
         preferences: Preferences,
         onCycleLayout: @escaping (CGDirectDisplayID) -> Void,
         onRetile: @escaping () -> Void,
         onShrinkMaster: @escaping () -> Void,
         onGrowMaster: @escaping () -> Void) {
        self.state = state
        self.preferences = preferences
        self.lastGeometry = BarGeometrySignature(preferences.activeBarPreset)
        self.onCycleLayout = onCycleLayout
        self.onRetile = onRetile
        self.onShrinkMaster = onShrinkMaster
        self.onGrowMaster = onGrowMaster

        rebuild(onCycleLayout: onCycleLayout,
                onRetile: onRetile,
                onShrinkMaster: onShrinkMaster,
                onGrowMaster: onGrowMaster)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Two things are polled here. `visibleFrame` changes when an auto-hiding
        // menu bar or Dock slides in or out and emits no notification, and the
        // pointer position drives the edge reveal. 30 Hz keeps the reveal feeling
        // immediate; both checks are simple property reads.
        //
        // `NSEvent.mouseLocation` is a plain public query for where the cursor
        // is. It is not an event tap and needs no Accessibility or Input
        // Monitoring consent.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncIfChanged()
                self?.updateEdgeReveal()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        preferences.observe { [weak self] in self?.presetGeometryChanged() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func rebuild(onCycleLayout: @escaping (CGDirectDisplayID) -> Void,
                         onRetile: @escaping () -> Void,
                         onShrinkMaster: @escaping () -> Void,
                         onGrowMaster: @escaping () -> Void) {
        topBars.forEach { $0.orderOut(nil) }
        bottomBars.forEach { $0.orderOut(nil) }
        topBars.removeAll()
        bottomBars.removeAll()

        routers.removeAll()
        let preset = preferences.activeBarPreset

        for screen in NSScreen.screens {
            let context = BarContext(state: state,
                                     preferences: preferences,
                                     displayID: screen.displayID,
                                     onCycleLayout: onCycleLayout,
                                     onRetile: onRetile,
                                     onShrinkMaster: onShrinkMaster,
                                     onGrowMaster: onGrowMaster)

            let top = makeBar(edge: .top, layout: preset.top, context: context, on: screen)
            topBars.append(top)

            let bottom = makeBar(edge: .bottom, layout: preset.bottom,
                                 context: context, on: screen)
            bottomBars.append(bottom)
        }
        lastVisibleFrames = NSScreen.screens.map(\.visibleFrame)
        revealByDisplay = revealByDisplay.filter { entry in
            NSScreen.screens.contains { $0.displayID == entry.key }
        }
    }

    @objc private func screenParametersChanged() {
        rebuildIfScreensChanged()
        syncPositions()
        onGeometryChange?()
    }

    /// A connected or disconnected display needs its bars created or torn down,
    /// not just repositioned. Resolution/Dock changes keep the same screens and
    /// are handled by `syncPositions` alone.
    private func rebuildIfScreensChanged() {
        guard NSScreen.screens.count != topBars.count else { return }
        rebuild(onCycleLayout: onCycleLayout,
                onRetile: onRetile,
                onShrinkMaster: onShrinkMaster,
                onGrowMaster: onGrowMaster)
    }

    private func syncIfChanged() {
        let current = NSScreen.screens.map(\.visibleFrame)
        guard current != lastVisibleFrames else { return }
        lastVisibleFrames = current
        rebuildIfScreensChanged()
        syncPositions()
        onGeometryChange?()
    }

    private func syncPositions() {
        for (index, screen) in NSScreen.screens.enumerated() {
            if index < topBars.count { topBars[index].reposition(on: screen) }
            if index < bottomBars.count { bottomBars[index].reposition(on: screen) }
        }
    }

    /// Slide a bar out of the way when the pointer reaches its edge, so it stops
    /// covering whatever the user is reaching for — the menu bar above, the Dock
    /// below. Evaluated per display: the pointer can only be on one screen, and
    /// `EdgeReveal` restores a display's bars once the pointer has left it.
    private func updateEdgeReveal() {
        let pointer = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            var reveal = revealByDisplay[screen.displayID] ?? EdgeReveal()
            guard reveal.update(pointer: pointer, screen: screen.frame) else { continue }
            revealByDisplay[screen.displayID] = reveal
            for bar in topBars where bar.displayID == screen.displayID {
                bar.setHiddenAtEdge(reveal.topHidden)
            }
            for bar in bottomBars where bar.displayID == screen.displayID {
                bar.setHiddenAtEdge(reveal.bottomHidden)
            }
        }
    }

    /// The area left for tiled windows on `screen`: the visible frame with both
    /// bars carved out.
    ///
    /// Deliberately unaffected by the edge reveal. Giving the space back while a
    /// bar is hidden would re-tile every window each time the pointer brushed an
    /// edge, which is a far worse experience than a 26pt strip being briefly
    /// unused.
    func tilingArea(on screen: NSScreen) -> CGRect {
        // Top and bottom can differ in height and in whether they float, so the
        // two edges are subtracted independently rather than as one doubled
        // thickness.
        let preset = preferences.activeBarPreset
        var area = screen.visibleFrame
        area.origin.y += reserved(for: preset.bottom)
        area.size.height -= reserved(for: preset.top) + reserved(for: preset.bottom)
        return area
    }

    /// A floating bar also reserves the gap it floats in — leaving a window
    /// under that gap would put it behind the bar's shadow.
    private func reserved(for layout: BarLayout) -> CGFloat {
        layout.height + (layout.floating ? Self.floatingMargin * 2 : 0)
    }

    private func makeBar(edge: BarEdge, layout: BarLayout,
                         context: BarContext, on screen: NSScreen) -> BarWindow {
        let router = ZoneScrollRouter()
        let bar = BarWindow(edge: edge,
                            thickness: layout.height,
                            margin: layout.floating ? Self.floatingMargin : 0,
                            router: router,
                            content: BarView(edge: edge,
                                             context: context,
                                             router: router,
                                             preferences: preferences,
                                             state: state))
        routers[ObjectIdentifier(bar)] = router
        bar.reposition(on: screen)
        bar.orderFront(nil)
        return bar
    }

    /// What a floating bar insets from the screen edges. A named constant rather
    /// than a preference: "floating" is the choice, and the number is what makes
    /// it read as floating.
    private static let floatingMargin: CGFloat = 10

    /// A preset change alters bar geometry, which is fixed at construction, so
    /// the windows are rebuilt and the tiler re-run against the area that leaves.
    /// Every other preference reaches the bars through SwiftUI.
    private func presetGeometryChanged() {
        let signature = BarGeometrySignature(preferences.activeBarPreset)
        guard signature != lastGeometry else { return }
        lastGeometry = signature
        rebuild(onCycleLayout: onCycleLayout,
                onRetile: onRetile,
                onShrinkMaster: onShrinkMaster,
                onGrowMaster: onGrowMaster)
        onGeometryChange?()
    }
}

/// The parts of a preset that are baked into a window when it is created, so a
/// change to any of them means the bars must be rebuilt rather than repainted.
private struct BarGeometrySignature: Equatable {
    let topHeight: Double
    let topFloating: Bool
    let bottomHeight: Double
    let bottomFloating: Bool

    init(_ preset: BarPreset) {
        topHeight = preset.top.height
        topFloating = preset.top.floating
        bottomHeight = preset.bottom.height
        bottomFloating = preset.bottom.floating
    }
}
