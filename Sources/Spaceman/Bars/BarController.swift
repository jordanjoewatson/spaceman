import AppKit
import SwiftUI
import SpacemanCore

/// Owns one top and one bottom bar per screen and keeps them positioned.
///
/// Placement is `BarPlacement`: bars rest on `visibleFrame`, and a positive
/// top-bar offset slides them up into the menu-bar / camera strip when the
/// user wants that. Display changes, Dock repositioning and auto-hide still
/// come from the public `NSScreen` notifications and a short poll — no Screen
/// Recording consent, no private API.
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
    private var lastOffsetsJSON: String
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
        self.lastOffsetsJSON = preferences[Defaults.barDisplayOffsets]
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

        preferences.observe { [weak self] in self?.preferencesChanged() }
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
        lastOffsetsJSON = preferences[Defaults.barDisplayOffsets]
        revealByDisplay = revealByDisplay.filter { entry in
            NSScreen.screens.contains { $0.displayID == entry.key }
        }
    }

    @objc private func screenParametersChanged() {
        applyScreenChange(NSScreen.screens.map(ScreenSnapshot.init))
    }

    /// A connected or disconnected display needs its bars created or torn down,
    /// not just repositioned.
    private func syncIfChanged() {
        let current = NSScreen.screens.map(ScreenSnapshot.init)
        guard current != lastScreens else { return }
        applyScreenChange(current)
    }

    private func applyScreenChange(_ current: [ScreenSnapshot]) {
        let idsChanged = current.map(\.id) != lastScreens.map(\.id)
        lastScreens = current
        if idsChanged || current.count != topBars.count {
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
            let offsets = preferences.barOffsets(for: screen.displayID)
            if index < topBars.count { topBars[index].reposition(on: screen, offsetY: CGFloat(offsets.top)) }
            if index < bottomBars.count { bottomBars[index].reposition(on: screen, offsetY: CGFloat(offsets.bottom)) }
        }
    }

    /// Slide a bar out of the way when the pointer reaches its edge, so it stops
    /// covering whatever the user is reaching for — the menu bar above, the Dock
    /// below. Evaluated per display: the pointer can only be on one screen, and
    /// `EdgeReveal` restores a display's bars once the pointer has left it.
    /// Off when `bar.edgeReveal` is false: bars stay put.
    private func updateEdgeReveal() {
        guard preferences[Defaults.barEdgeReveal] else {
            restoreRevealedBars()
            return
        }
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

    /// Bring every bar back after auto-hide is turned off, or a display goes away.
    private func restoreRevealedBars() {
        guard !revealByDisplay.isEmpty else { return }
        revealByDisplay.removeAll()
        for bar in topBars { bar.setHiddenAtEdge(false) }
        for bar in bottomBars { bar.setHiddenAtEdge(false) }
    }

    /// The area left for tiled windows on `screen`: from the inner edge of the
    /// bottom bar to the inner edge of the top bar, still clamped to
    /// `visibleFrame` so windows never enter the Dock or system menu bar.
    ///
    /// Offsets are included because the bar's actual frame is what tiles
    /// against. Deliberately unaffected by the edge reveal: giving the space
    /// back while a bar is hidden would re-tile every window each time the
    /// pointer brushed an edge.
    func tilingArea(on screen: NSScreen) -> CGRect {
        let preset = preferences.activeBarPreset
        var area = screen.visibleFrame
        let bottom = reserved(edge: .bottom, layout: preset.bottom, on: screen)
        let top = reserved(edge: .top, layout: preset.top, on: screen)
        area.origin.y += bottom
        area.size.height -= top + bottom
        return area
    }

    /// How far `visibleFrame` is inset to the bar's inner edge.
    private func reserved(edge: BarPlacement.Edge, layout: BarLayout,
                          on screen: NSScreen) -> CGFloat {
        let thickness = CGFloat(layout.height)
        let frame = BarPlacement.windowFrame(
            edge: edge,
            visibleFrame: screen.visibleFrame,
            thickness: thickness,
            margin: layout.floating ? Self.floatingMargin : 0,
            offsetY: offset(for: edge, displayID: screen.displayID))
        return BarPlacement.visibleInset(edge: edge, bar: frame,
                                         visibleFrame: screen.visibleFrame)
    }

    private func makeBar(edge: BarEdge, layout: BarLayout,
                         context: BarContext, on screen: NSScreen) -> BarWindow {
        let placementEdge: BarPlacement.Edge = edge == .top ? .top : .bottom
        let thickness = CGFloat(layout.height)
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
        bar.reposition(on: screen, offsetY: offset(for: placementEdge, displayID: screen.displayID))
        bar.orderFront(nil)
        return bar
    }

    private func offset(for edge: BarPlacement.Edge,
                        displayID: CGDirectDisplayID) -> CGFloat {
        let offsets = preferences.barOffsets(for: displayID)
        switch edge {
        case .top:    return CGFloat(offsets.top)
        case .bottom: return CGFloat(offsets.bottom)
        }
    }

    /// What a floating bar insets from the screen edges. A named constant rather
    /// than a preference: "floating" is the choice, and the number is what makes
    /// it read as floating.
    private static let floatingMargin: CGFloat = 10

    /// A preset change alters bar geometry, which is fixed at construction, so
    /// the windows are rebuilt and the tiler re-run against the area that leaves.
    /// Every other preference reaches the bars through SwiftUI.
    private func preferencesChanged() {
        let offsetsJSON = preferences[Defaults.barDisplayOffsets]
        if offsetsJSON != lastOffsetsJSON {
            lastOffsetsJSON = offsetsJSON
            syncPositions()
            onGeometryChange?()
        }

        presetGeometryChanged()
    }

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
/// nudge.
private struct ScreenSnapshot: Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
    var visible: CGRect

    init(_ screen: NSScreen) {
        id = screen.displayID
        frame = screen.frame
        visible = screen.visibleFrame
    }
}
