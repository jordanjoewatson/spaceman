import AppKit
import SwiftUI
import SpacemanCore

/// Owns one top and one bottom bar per screen and keeps them positioned.
///
/// Placement is `BarPlacement`: `visibleFrame` for the Dock, menu bar, and
/// floating bars; the full `screen.frame` for a flush top bar on a notched
/// display so the ears either side of the camera are filled rather than left
/// empty. Display changes, Dock repositioning and auto-hide still come from
/// the public `NSScreen` notifications and a short poll — no Screen Recording
/// consent, no private API.
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
    private var lastScreens: [ScreenSnapshot] = []
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
        lastScreens = NSScreen.screens.map(ScreenSnapshot.init)
        revealByDisplay = revealByDisplay.filter { entry in
            NSScreen.screens.contains { $0.displayID == entry.key }
        }
    }

    @objc private func screenParametersChanged() {
        applyScreenChange(NSScreen.screens.map(ScreenSnapshot.init))
    }

    /// A connected or disconnected display needs its bars created or torn down,
    /// not just repositioned. A change in the camera-strip height also needs a
    /// rebuild: that thickness is baked into the window when it is created.
    private func syncIfChanged() {
        let current = NSScreen.screens.map(ScreenSnapshot.init)
        guard current != lastScreens else { return }
        applyScreenChange(current)
    }

    private func applyScreenChange(_ current: [ScreenSnapshot]) {
        let idsChanged = current.map(\.id) != lastScreens.map(\.id)
        let notchChanged = current.map(\.safeTop) != lastScreens.map(\.safeTop)
        lastScreens = current
        if idsChanged || notchChanged || current.count != topBars.count {
            rebuild(onCycleLayout: onCycleLayout,
                    onRetile: onRetile,
                    onShrinkMaster: onShrinkMaster,
                    onGrowMaster: onGrowMaster)
        }
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

    /// The area left for tiled windows on `screen`: the visible frame with any
    /// bar that actually sits in it carved out.
    ///
    /// A flush top bar on a notched display lives in the camera strip that
    /// `visibleFrame` already excludes, so it contributes nothing here — we
    /// must not subtract the same strip twice. Deliberately unaffected by the
    /// edge reveal: giving the space back while a bar is hidden would re-tile
    /// every window each time the pointer brushed an edge.
    func tilingArea(on screen: NSScreen) -> CGRect {
        let preset = preferences.activeBarPreset
        var area = screen.visibleFrame
        let bottom = reserved(edge: .bottom, layout: preset.bottom, on: screen)
        let top = reserved(edge: .top, layout: preset.top, on: screen)
        area.origin.y += bottom
        area.size.height -= top + bottom
        return area
    }

    /// How much of `visibleFrame` this bar occupies, plus the floating gap.
    private func reserved(edge: BarPlacement.Edge, layout: BarLayout,
                          on screen: NSScreen) -> CGFloat {
        let thickness = BarPlacement.thickness(
            edge: edge,
            requested: CGFloat(layout.height),
            floating: layout.floating,
            safeAreaTop: screen.safeAreaInsets.top)
        let frame = BarPlacement.windowFrame(
            edge: edge,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            thickness: thickness,
            margin: layout.floating ? Self.floatingMargin : 0)
        var used = BarPlacement.visibleHeightUsed(bar: frame, visibleFrame: screen.visibleFrame)
        if layout.floating {
            used += Self.floatingMargin * 2
        }
        return used
    }

    private func makeBar(edge: BarEdge, layout: BarLayout,
                         context: BarContext, on screen: NSScreen) -> BarWindow {
        let placementEdge: BarPlacement.Edge = edge == .top ? .top : .bottom
        let thickness = BarPlacement.thickness(
            edge: placementEdge,
            requested: CGFloat(layout.height),
            floating: layout.floating,
            safeAreaTop: screen.safeAreaInsets.top)
        let router = ZoneScrollRouter()
        let bar = BarWindow(edge: edge,
                            thickness: thickness,
                            margin: layout.floating ? Self.floatingMargin : 0,
                            router: router,
                            content: BarView(edge: edge,
                                             barHeight: thickness,
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

/// Enough of an `NSScreen` to decide whether bars need a rebuild or just a
/// nudge. `safeTop` is the camera-strip height; it is baked into window
/// thickness, so a change there cannot be handled by `setFrame` alone.
private struct ScreenSnapshot: Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var visible: CGRect
    var safeTop: CGFloat

    init(_ screen: NSScreen) {
        id = screen.displayID
        frame = screen.frame
        visible = screen.visibleFrame
        safeTop = screen.safeAreaInsets.top
    }
}
