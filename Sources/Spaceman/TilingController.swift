import AppKit
import SpacemanCore

/// Which side of the current display to send a window to.
enum DisplayDirection {
    case left, right
}

/// Tiles the windows on the current Space.
///
/// Deliberately a *reconciliation loop*, not an event stream: every pass
/// re-derives the truth from the window server, so a move that silently failed
/// simply gets retried instead of leaving the model out of sync with reality.
@MainActor
final class TilingController {

    private let state: BarState
    private let bars: BarController
    private let ledger: SpaceLedger
    private var mover: WindowMover

    /// Layout choice is remembered per Space. This is the only thing the Space
    /// ledger is used for — we never create, destroy or switch Spaces.
    private var modeBySpace: [SpaceLedger.SpaceID: LayoutMode] = [:]

    /// Slot assignment per Space, by window ID.
    ///
    /// Without this, slots are assigned by z-order, so merely focusing a window
    /// promotes it to master and the layout reshuffles — and returning to a
    /// Space with a different window focused moves everything. A window keeps
    /// its slot until it closes; newcomers take the next free one.
    private var orderBySpace: [SpaceLedger.SpaceID: SlotOrder] = [:]

    /// Layout tuning comes from preferences rather than being owned here, so a
    /// `defaults write` and the Settings window and ⌃⌥± all move the same value.
    private var params: LayoutParams { preferences.layoutParams }

    /// The zoomed window per Space — a floating 80%-of-area "fullscreen" over
    /// the tiled rest (the Go version's `zoomed[region]`).
    private var zoomBySpace: [SpaceLedger.SpaceID: CGWindowID] = [:]

    /// Windows currently gliding out to the Dock. The reconciler excludes them
    /// immediately, so the rest reflow while the genie animation plays rather
    /// than after it — the Go version's minimize choreography.
    private var pendingMinimize: Set<CGWindowID> = []

    private var timer: Timer?

    /// Readiness is logged and surfaced once per transition, not every 50ms.
    private var moverWasReady = false

    /// Window IDs seen on the previous pass, and when that set first appeared.
    /// A set must hold still for `stabilityWindow` before it is acted on.
    private var lastSignature: [CGWindowID]?
    private var signatureSince = Date.distantPast

    /// How long a *membership* change must hold still before being acted on —
    /// a debounce against window create/destroy churn, not a Space-transition
    /// guard: exact Space tags (`CGSSpaces`) already keep a slide from ever
    /// presenting a mixed window set. Kept short so a newly opened window is
    /// placed quickly — the Go version reacts ~80ms after the create event.
    private static let stabilityWindow: TimeInterval = 0.1

    /// Animation is opt-out; it only ever engages on a mover that can sustain
    /// display-rate updates, and never when Reduce Motion is on.
    var animationsEnabled: Bool {
        get { preferences.animationsEnabled }
        set { preferences.animationsEnabled = newValue }
    }

    /// Per-window resize weights, per Space. Empty until something is resized,
    /// which is what keeps an untouched layout on the equal-split path.
    private var weightsBySpace: [SpaceLedger.SpaceID: ResizeWeights] = [:]

    /// Stops the app re-asking windows for frames they have already refused.
    private var placements = PlacementTracker()

    /// Last display-assignment description emitted for each window. Assignment
    /// is evaluated at 20 Hz, so diagnostics are only useful when something
    /// changes (especially when a window starts alternating between displays).
    private var lastDisplayDiagnostics: [CGWindowID: String] = [:]

    private let preferences: Preferences
    private let animator = Animator()
    /// Set while an animation owns the window frames, so the reconciler does not
    /// fight it by re-issuing moves against intermediate positions.
    private var isAnimating = false

    init(state: BarState, bars: BarController, ledger: SpaceLedger,
         preferences: Preferences) {
        self.state = state
        self.bars = bars
        self.ledger = ledger
        self.preferences = preferences
        self.mover = MoverFactory.makeDefault()

        state.moverName = mover.name
        state.moverReady = mover.isReady

        ledger.onSpaceChange = { [weak self] in
            guard let self else { return }
            self.ledger.resolveAll()
            self.syncSpaceState()
            // Do not tile immediately. A Space slide reports transient frames
            // whose centres sit on the other display; an AX move there
            // permanently re-homes the window. The 20 Hz tick plus the
            // membership debounce places the new set after the slide settles.
        }
    }

    private func windowSignature() -> [CGWindowID] {
        tileableNow().map(\.id).sorted()
    }

    /// The windows the reconciler should act on right now: the on-screen set
    /// minus anything mid-minimize.
    private func tileableNow() -> [ManagedWindow] {
        let all = WindowSource.currentSpaceWindows()
        guard !pendingMinimize.isEmpty else { return all }
        // A window that left the screen has finished minimizing; drop the marker.
        pendingMinimize.formIntersection(all.map(\.id))
        return all.filter { !pendingMinimize.contains($0.id) }
    }

    func start() {
        ledger.resolveAll()
        syncSpaceState()

        // 20 Hz. Enumeration measures 0.14ms median, so this costs ~0.3% of one
        // core and makes a manual resize snap back in under a frame or two
        // instead of up to half a second. Membership changes are still held by
        // `stabilityWindow`, which is a duration rather than a pass count, so
        // raising the poll rate does not weaken it.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        tileNow()
    }

    // MARK: - Commands

    /// Push per-display Space dots and layout modes into the bar state.
    /// Sets are guarded so the 20 Hz tick doesn't churn SwiftUI.
    private func syncSpaceState() {
        for (displayID, space) in ledger.currentByDisplay {
            let dots = (ledger.spacesByDisplay[displayID] ?? [space]).map {
                SpaceDot(isCurrent: $0.raw == space.raw)
            }
            if state.spaceDots[displayID] != dots {
                state.spaceDots[displayID] = dots
            }
            let current = mode(for: space)
            if state.layoutModes[displayID] != current {
                state.layoutModes[displayID] = current
            }
        }
    }

    /// The Space an action applies to: a given display's current Space (bar
    /// buttons act on their own display), or the one receiving keyboard input
    /// (hotkeys, the menu, the URL scheme).
    private func spaceForAction(on displayID: CGDirectDisplayID?) -> SpaceLedger.SpaceID {
        displayID.map { ledger.current(for: $0) } ?? ledger.active()
    }

    func cycleLayout(on displayID: CGDirectDisplayID? = nil) {
        setLayout(mode(for: spaceForAction(on: displayID)).next, on: displayID)
    }

    func setLayout(_ mode: LayoutMode, on displayID: CGDirectDisplayID? = nil) {
        modeBySpace[spaceForAction(on: displayID)] = mode
        syncSpaceState()
        tileNow()
    }

    /// ⌃⌥± and the bar's ± buttons. The new ratio is written to preferences —
    /// clamped there — so it survives a restart rather than being re-set every
    /// session.
    func adjustMaster(by delta: CGFloat) {
        preferences[Defaults.masterRatio] += Double(delta)
        tileNow()
    }

    /// ⌃⌥F: toggle the focused window's zoom — a floating 80%-of-area
    /// "fullscreen" that stays above the tiled rest, whose grid slots stay put
    /// underneath (the Go version's `ZoomFocused`). The window's own display
    /// determines which Space's zoom toggles.
    func toggleZoom() {
        guard let focused = WindowFocus.focused(),
              let window = tileableNow().first(where: { $0.id == focused.id }),
              let screen = NSScreen.screens.first(where: {
                  $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
              }) else { return }
        let space = ledger.current(for: screen.displayID)
        if zoomBySpace[space] == focused.id {
            zoomBySpace[space] = nil
        } else {
            zoomBySpace[space] = focused.id
            // Raise the zoomed window above the rest.
            WindowFocus.focus(pid: focused.pid, id: focused.id)
        }
        tileNow()
    }

    /// ⌃⌥M: minimize the focused window. The remaining windows reflow while
    /// the genie animation plays — the AX setter blocks for it, so it runs off
    /// the main thread (the Go version's `MinimizeFocused`).
    func minimizeFocused() {
        guard let focused = WindowFocus.focused() else { return }
        pendingMinimize.insert(focused.id)
        tileNow()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = WindowFocus.minimize(pid: focused.pid, id: focused.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !ok {
                        // Never happened, as far as the layout is concerned.
                        self.pendingMinimize.remove(focused.id)
                        self.tileNow()
                    }
                    // On success the window leaves the screen and the
                    // reconciler drops the marker itself (`tileableNow`).
                }
            }
        }
    }

    /// ⌃⌥ + arrow: move keyboard focus to the tiled window nearest the focused
    /// one in that direction (the Go version's `FocusDir`).
    func focus(_ direction: FocusDirection) {
        guard let focused = WindowFocus.focused() else { return }
        let windows = tileableNow()
        let targets = plannedTargets(windows)
        guard let best = FocusNavigation.neighbor(of: focused.id, in: targets,
                                                  direction: direction),
              let window = windows.first(where: { $0.id == best }) else { return }
        WindowFocus.focus(pid: window.pid, id: window.id)
    }

    /// Every tiled window with the frame the layout intends for it, for
    /// focus-follows-mouse hit testing.
    ///
    /// Planned frames rather than live ones, so a window still gliding into
    /// place is tested where it will land — otherwise the pointer resting still
    /// would appear to move between windows as they animate.
    func focusTargets() -> [(id: CGWindowID, pid: pid_t, frame: CGRect)] {
        let windows = tileableNow()
        let rects = plannedTargets(windows)
        return windows.compactMap { window in
            rects[window.id].map { (window.id, window.pid, $0) }
        }
    }

    // MARK: - Resizing

    /// Translate this Space's per-window weights into the slot-indexed form the
    /// layout engine takes.
    private func layoutWeights(for ordered: [ManagedWindow],
                               space: SpaceLedger.SpaceID) -> LayoutWeights? {
        guard let weights = weightsBySpace[space], !weights.isEmpty else { return nil }
        return LayoutWeights(widths: ordered.map { weights.width($0.id) },
                             heights: ordered.map { weights.height($0.id) })
    }

    /// ⌃⌥⇧ + arrow: resize the focused window.
    ///
    /// → wider, ← narrower, ↑ taller, ↓ shorter.
    ///
    /// Not "grow toward the arrow", which is what the Go version does and what
    /// this was first written as. That model cannot shrink a window with
    /// neighbours on both sides — every arrow grows it, and the only way to make
    /// it smaller is to focus a neighbour and grow *that*. An axis plus a
    /// direction gives both, and reads the way a size control should.
    ///
    /// Which border moves is then chosen rather than pressed: the neighbour away
    /// from the screen edge, preferring the trailing side.
    func resize(_ direction: FocusDirection) {
        guard let focused = WindowFocus.focused() else { return }
        let windows = tileableNow()
        let rects = plannedTargets(windows)
        guard let current = rects[focused.id],
              let window = windows.first(where: { $0.id == focused.id }) else { return }

        let horizontal = direction == .left || direction == .right
        let growing = direction == .right || direction == .up

        // Look along the axis for something to trade with. Trailing first, so a
        // window in the middle of a row resizes against the same neighbour every
        // time rather than depending on which arrow was pressed.
        let forward: FocusDirection = horizontal ? .right : .up
        let backward: FocusDirection = horizontal ? .left : .down
        guard let neighbor = ResizeNavigation.neighbor(of: focused.id, in: rects,
                                                       direction: forward)
                ?? ResizeNavigation.neighbor(of: focused.id, in: rects,
                                             direction: backward) else { return }

        let space = displayID(of: window).map { ledger.current(for: $0) } ?? ledger.active()

        // In the master layout the only horizontal border is the master/stack
        // split, so width moves the ratio rather than a weight — and which way
        // depends on which side of the split the window is on, not on the arrow.
        if horizontal, mode(for: space) == .masterStack {
            let isMaster = stableOrder(windows, space: space).first?.id == focused.id
            let widening = growing == isMaster
            preferences[Defaults.masterRatio] += widening
                ? ResizeWeights.step * 0.5
                : -ResizeWeights.step * 0.5
            tileNow()
            return
        }

        var weights = weightsBySpace[space] ?? ResizeWeights()
        let changed: Bool

        if horizontal {
            changed = growing
                ? weights.growWidth(of: focused.id, from: neighbor)
                : weights.growWidth(of: neighbor, from: focused.id)
        } else {
            // Vertically, a whole grid row moves as one — the border belongs to
            // the row, not to a single cell. The master layout stacks each
            // column independently, so there it really is just the two cells.
            let rowResize = mode(for: space) != .masterStack
            let mine = rowResize
                ? ResizeNavigation.rowMembers(of: current, in: rects)
                : [focused.id]
            let theirs = rects[neighbor].map { neighborRect in
                rowResize
                    ? ResizeNavigation.rowMembers(of: neighborRect, in: rects)
                    : [neighbor]
            } ?? [neighbor]

            changed = growing
                ? weights.growHeight(of: mine, from: theirs)
                : weights.growHeight(of: theirs, from: mine)
        }

        // Nothing moved — both sides are already at a limit — so there is no
        // layout to re-run.
        guard changed else { return }
        weightsBySpace[space] = weights
        placements.reset()
        tileNow()
    }

    /// Back to an equal split on the focused window's Space.
    func resetSizes() {
        let space = WindowFocus.focused()
            .flatMap { focused in tileableNow().first { $0.id == focused.id } }
            .flatMap(displayID(of:))
            .map { ledger.current(for: $0) } ?? ledger.active()
        guard weightsBySpace[space] != nil else { return }
        weightsBySpace[space] = nil
        placements.reset()
        tileNow()
    }

    // MARK: - Swapping

    /// The focused window and everything sharing its tiling region, with the
    /// frames the layout intends for them.
    ///
    /// Planned frames rather than live ones, so a window still gliding into
    /// place is reported where it will land — swap mode draws rings on these,
    /// and a ring on a mid-animation frame would sit visibly off its window.
    func swapCandidates() -> (focused: CGWindowID?, rects: [CGWindowID: CGRect]) {
        guard let focused = WindowFocus.focused() else { return (nil, [:]) }
        let windows = tileableNow()
        let targets = plannedTargets(windows)
        guard let focusedFrame = targets[focused.id] else { return (nil, [:]) }

        // Same region means same display: a window only ever takes a slot on the
        // display its centre sits on, so swapping across displays would exchange
        // slots that were never comparable.
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: focusedFrame.midX, y: focusedFrame.midY))
        }) else { return (focused.id, targets) }

        let sameDisplay = targets.filter { _, rect in
            screen.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        return (focused.id, sameDisplay)
    }

    /// The tiled window nearest `id` in `direction`, by the same spatial rule
    /// focus movement uses — so swap mode's arrows agree with ⌃⌥ arrows.
    func tiledNeighbor(of id: CGWindowID, direction: FocusDirection) -> CGWindowID? {
        FocusNavigation.neighbor(of: id, in: swapCandidates().rects, direction: direction)
    }

    /// Exchange two windows' tiled slots.
    ///
    /// Persists through re-tiling because the slot order *is* the model — the
    /// next pass lays out against the swapped order rather than re-deriving it.
    /// Focus stays on the window the user was driving, which is the one they
    /// were looking at when they hit Enter.
    func swap(_ a: CGWindowID, _ b: CGWindowID) {
        let windows = tileableNow()
        guard let first = windows.first(where: { $0.id == a }),
              windows.contains(where: { $0.id == b }) else { return }

        // Both windows share a region, so one Space's order holds both slots.
        let space = displayID(of: first).map { ledger.current(for: $0) } ?? ledger.active()
        var order = orderBySpace[space] ?? SlotOrder()
        guard order.swap(a, b) else { return }
        orderBySpace[space] = order

        // Both windows are about to be asked for frames they previously refused
        // — they are each moving to where the other just was — so the refusal
        // record has to go, or the swap would be skipped as a no-op.
        placements.reset()
        tileNow()
        WindowFocus.focus(pid: first.pid, id: first.id)
    }

    private func displayID(of window: ManagedWindow) -> CGDirectDisplayID? {
        if !window.spaceIDs.isEmpty {
            for (displayID, space) in ledger.currentByDisplay
            where window.spaceIDs.contains(space.raw) {
                return displayID
            }
        }
        return NSScreen.screens.first {
            $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
        }?.displayID
    }

    /// ⌃⌥⌘← / ⌃⌥⌘→: move the focused window to the display on that side,
    /// wrapping at the ends. A plain Accessibility frame move: macOS re-tags
    /// the window onto whatever Space the target display is showing, so no
    /// private Space-move API is involved. The reconciler then glides it into
    /// a slot on its new display and reflows the old one.
    func moveFocusedToDisplay(_ direction: DisplayDirection) {
        guard NSScreen.screens.count > 1,
              let focused = WindowFocus.focused(),
              let window = tileableNow().first(where: { $0.id == focused.id }),
              let current = NSScreen.screens.first(where: {
                  $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
              }),
              let target = screen(beyond: current, direction: direction) else { return }

        // Leaving a Space cancels any zoom the window held there.
        for (space, zoomed) in zoomBySpace where zoomed == focused.id {
            zoomBySpace[space] = nil
        }

        let area = bars.tilingArea(on: target)
        var frame = window.frame
        frame.origin = CGPoint(x: area.midX - frame.width / 2,
                               y: area.midY - frame.height / 2)
        let quartz = Coordinates.toQuartz(frame)
        guard WindowFocus.setPosition(pid: window.pid, id: window.id, quartz.origin) else { return }

        WindowFocus.focus(pid: window.pid, id: window.id)
        // Bring the pointer along: no macOS command moves it between displays,
        // and a keyboard-driven move loses the plot if the cursor stays behind.
        CGWarpMouseCursorPosition(CGPoint(x: quartz.midX, y: quartz.midY))
        tileNow()
    }

    /// ⌃⌥D: hop the pointer to the next display (left-to-right, wrapping),
    /// landing in the centre of its tiling area. No window moves and focus
    /// doesn't change — this is only the mouse. (There is no macOS command for
    /// this; `CGWarpMouseCursorPosition` is public API.)
    func warpPointerToNextDisplay() {
        let screens = NSScreen.screens.sorted { $0.frame.midX < $1.frame.midX }
        guard screens.count > 1 else { return }
        let mouse = NSEvent.mouseLocation
        let current = screens.firstIndex(where: { $0.frame.contains(mouse) }) ?? 0
        let area = bars.tilingArea(on: screens[(current + 1) % screens.count])
        CGWarpMouseCursorPosition(Coordinates.toQuartz(point: CGPoint(x: area.midX, y: area.midY)))
    }

    /// The display immediately to the left/right of `screen`, wrapping around
    /// the far end — with two displays either direction means "the other one".
    private func screen(beyond screen: NSScreen, direction: DisplayDirection) -> NSScreen? {
        let others = NSScreen.screens
            .filter { $0.displayID != screen.displayID }
            .sorted { $0.frame.midX < $1.frame.midX }
        guard !others.isEmpty else { return nil }
        switch direction {
        case .left:  return others.filter { $0.frame.midX < screen.frame.midX }.last ?? others.last
        case .right: return others.filter { $0.frame.midX > screen.frame.midX }.first ?? others.first
        }
    }

    /// Run one command. The single place a `Command` becomes an effect, so the
    /// menu, the URL scheme and the config file all take exactly the same path.
    func run(_ command: Command) {
        switch command {
        case .setLayout(let mode):   setLayout(mode)
        case .cycleLayout:           cycleLayout()
        case .retile:                tileNow()
        case .setMaster(let value):  preferences[Defaults.masterRatio] = Double(value); tileNow()
        case .adjustMaster(let d):   adjustMaster(by: d)
        case .setGap(let value):
            preferences[Defaults.gap] = Double(value)
            preferences[Defaults.outerGap] = Double(value)
            tileNow()
        case .setAnimation(let on):  animationsEnabled = on
        }
    }

    func run(_ script: CommandScript) {
        Log.debug("running command '\(script.name)' (\(script.commands.count) step(s))")
        for command in script.commands { run(command) }
    }

    func tileNow() {
        // An explicit request deserves a real attempt, even at a frame the
        // window refused before — the app may have changed its constraints.
        placements.reset()
        // And it acts on the window set as it stands, without the stability
        // wait — the user just asked, out loud, for exactly this set.
        lastSignature = windowSignature()
        signatureSince = .distantPast
        tick()
    }

    /// Keep each window in the slot it already holds; append newcomers.
    ///
    /// `WindowSource` returns front-to-back order, which changes every time the
    /// user clicks a window. Feeding that straight to the layout engine makes
    /// slot assignment a function of focus, so positions move for reasons the
    /// user did not ask for. Persisting the order per Space makes a placement
    /// stay put until the window set actually changes.
    private func stableOrder(_ windows: [ManagedWindow],
                             space: SpaceLedger.SpaceID) -> [ManagedWindow] {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order = orderBySpace[space] ?? SlotOrder()
        let ids = order.reconcile(present: windows.map(\.id))
        orderBySpace[space] = order
        return ids.compactMap { byID[$0] }
    }

    /// The target frame per window for the current layout — the Go version's
    /// `regionRects`. `tick` issues moves towards these; spatial focus
    /// navigation measures against them (a frame that's mid-animation still
    /// counts as where it will land).
    private func plannedTargets(_ windows: [ManagedWindow]) -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        var matchingDisplays: [CGWindowID: [CGDirectDisplayID]] = [:]
        var targetDisplay: [CGWindowID: CGDirectDisplayID] = [:]

        // Tile each display independently: a tiling region is one display × one
        // Space (the Go version's `Region`). Windows are assigned by Space
        // identity, not live frame centre — during a Space slide the centre
        // can sit on the other display, and an AX move there re-homes it.
        for screen in NSScreen.screens {
            let space = ledger.current(for: screen.displayID)
            let group = windows.filter { window in
                Displays.belongs(window, toSpace: space.raw, screen: screen.frame)
            }
            for window in group {
                matchingDisplays[window.id, default: []].append(screen.displayID)
            }
            guard !group.isEmpty else { continue }

            // Full-screen Spaces are the OS's own layout; leave them alone.
            // This has to be decided from the window list, not screen geometry
            // — see `isFullScreenSpace`.
            if SpaceLedger.isFullScreenSpace(windows: group, screen: screen) {
                Log.debug("skipping full-screen space on \(screen.localizedName)")
                continue
            }

            let ordered = stableOrder(group, space: space)
            let activeMode = mode(for: space)
            let area = bars.tilingArea(on: screen)
            var targets = Layout.frames(
                count: ordered.count,
                in: area,
                mode: activeMode,
                params: params,
                weights: layoutWeights(for: ordered, space: space)
            )
            guard !targets.isEmpty else { continue }

            // A zoomed window floats centered over the rest at `zoomFraction` of
            // the area; its grid slot stays put underneath.
            if let zoomed = zoomBySpace[space],
               let zi = ordered.firstIndex(where: { $0.id == zoomed }), zi < targets.count {
                targets[zi] = Layout.centered(in: area,
                                              fraction: preferences[Defaults.zoomFraction])
            }

            Log.debug("space=\(space) screen=\(screen.localizedName) mode=\(activeMode) "
                      + "area=\(area) windows=\(group.count)")
            for (w, t) in zip(ordered, targets) {
                Log.debug("  z=\(w.zOrder) \(w.ownerName) at=\(w.frame) -> \(t)")
                out[w.id] = t
                targetDisplay[w.id] = screen.displayID
            }
        }
        logDisplayAssignments(windows, matches: matchingDisplays,
                              targets: out, targetDisplays: targetDisplay)
        return out
    }

    /// Makes transient multi-display ownership visible without flooding stderr
    /// on every reconciliation tick. If a window is caught in the suspected
    /// feedback loop, successive lines will show `chosen` alternating; if it is
    /// eligible on more than one display, `matches` will contain both IDs.
    private func logDisplayAssignments(
        _ windows: [ManagedWindow],
        matches: [CGWindowID: [CGDirectDisplayID]],
        targets: [CGWindowID: CGRect],
        targetDisplays: [CGWindowID: CGDirectDisplayID]
    ) {
        guard Log.enabled else { return }

        let screens = NSScreen.screens
        let live = Set(windows.map(\.id))
        lastDisplayDiagnostics = lastDisplayDiagnostics.filter { live.contains($0.key) }

        for window in windows {
            let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let physical = screens.first { $0.frame.contains(centre) }?.displayID
            let matched = matches[window.id, default: []]
            let spaces = window.spaceIDs.sorted()
            let physicalDescription = physical.map { String($0) } ?? "none"
            let chosenDescription = targetDisplays[window.id].map { String($0) } ?? "none"
            let targetDescription = targets[window.id].map { String(describing: $0) } ?? "none"
            let detail = "frame=\(window.frame) centreDisplay=\(physicalDescription) "
                + "spaces=\(spaces) matches=\(matched) "
                + "chosen=\(chosenDescription) target=\(targetDescription)"

            guard lastDisplayDiagnostics[window.id] != detail else { continue }
            let warning = matched.count > 1 ? " AMBIGUOUS" : ""
            Log.debug("display-assignment\(warning) id=\(window.id) app=\(window.ownerName) \(detail)")
            lastDisplayDiagnostics[window.id] = detail
        }
    }

    // MARK: - Reconciliation

    private func tick() {
        // Space identity is refreshed every pass, even when nothing tiles —
        // the bars' labels must track Space switches on every display,
        // including a display showing an empty desktop.
        ledger.resolveAll()
        syncSpaceState()

        // An animation owns the frames until it completes.
        if isAnimating { return }

        // Without Accessibility consent there is nothing to do this pass. That
        // is a normal state — the user is often granting it right now — so keep
        // polling (recovery needs no restart), but say so once per transition
        // instead of suspending silently.
        let ready = mover.isReady
        state.moverReady = ready
        if ready != moverWasReady {
            moverWasReady = ready
            if ready {
                Log.debug("mover ready; tiling active")
            } else {
                Log.debug("mover not ready; tiling paused until Accessibility access is granted")
                state.note("Grant Accessibility access to enable tiling")
            }
        }
        guard ready else { return }

        let raw = tileableNow()
        guard !raw.isEmpty else { return }

        // Act only on a window set that was already there last pass.
        //
        // This is a debounce against window create/destroy churn, not a
        // Space-transition guard — windows are filtered by their exact Space
        // tag, so a slide can never present a mixed set here.
        //
        // The signature is window IDs only, so this costs nothing in the common
        // case: dragging or resizing a window leaves the set unchanged and is
        // acted on immediately. Only membership changes wait one pass.
        let signature = raw.map(\.id).sorted()
        if signature != lastSignature {
            Log.debug("window set changed (\(lastSignature?.count ?? 0) -> \(signature.count)); "
                      + "waiting for it to settle")
            lastSignature = signature
            signatureSince = Date()
            return
        }
        guard Date().timeIntervalSince(signatureSince) >= Self.stabilityWindow else { return }

        // Judge last pass's requests, then drop anything already refused.
        placements.observe(windows: raw, tolerance: 4)
        let liveIDs = Set(raw.map(\.id))
        placements.retain(only: liveIDs)
        // A closed window's weights must go with it, or a reused window id
        // inherits a dead window's share of the layout.
        for space in weightsBySpace.keys {
            weightsBySpace[space]?.retain(only: liveIDs)
        }
        mover.retain(only: liveIDs)

        // A zoomed window that left (closed, minimized, moved off-Space) isn't
        // zoomed anymore.
        for (space, zoomed) in zoomBySpace where !liveIDs.contains(zoomed) {
            zoomBySpace[space] = nil
        }

        let targets = plannedTargets(raw)
        let tiled = raw.filter { targets[$0.id] != nil }

        var moves: [Move] = []
        var refusedCount = 0
        for move in Reconciler.moves(windows: tiled, targets: tiled.map { targets[$0.id]! }) {
            if placements.isRefused(move.window.id, target: move.target, tolerance: 4) {
                refusedCount += 1
            } else {
                moves.append(move)
            }
        }

        if refusedCount > 0 {
            Log.debug("  skipping \(refusedCount) refused target(s)")
        }
        Log.debug("  moves=\(moves.count) mover=\(mover.name) ready=\(mover.isReady)")
        guard !moves.isEmpty else { return }
        placements.record(moves)

        guard mover.supportsAnimation, animationsEnabled else {
            applyDirectly(moves)
            return
        }

        // Hand the frames to the animator and stand down until it finishes.
        // Without this the reconciler would see each interpolated frame as
        // "wrong" and issue a competing move on the next tick.
        isAnimating = true
        animator.duration = preferences.animationDuration
        animator.run(
            moves: moves,
            applyFrame: { [weak self] frame in self?.applyFrame(frame) },
            apply: { [weak self] frame in self?.applyDirectly(frame) },
            completion: { [weak self] in
                guard let self else { return }
                self.isAnimating = false
            }
        )
    }

    private func applyFrame(_ moves: [Move]) {
        do { try mover.applyFrame(moves) } catch { /* judged on the final apply */ }
    }

    private func applyDirectly(_ moves: [Move]) {
        do {
            try mover.apply(moves)
        } catch {
            // A failed final apply is judged by the reconciler on the next pass:
            // the window is still off-target, so the move is re-issued unless
            // the placement tracker has seen it refused.
            animator.cancel()
            isAnimating = false
            state.note(error.localizedDescription)
            Log.debug("apply failed: \(error.localizedDescription)")
        }
    }

    /// A Space the user hasn't set a layout on uses `tiling.defaultLayout`.
    private func mode(for id: SpaceLedger.SpaceID) -> LayoutMode {
        modeBySpace[id] ?? preferences.defaultLayout
    }
}
