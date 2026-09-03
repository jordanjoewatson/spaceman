import AppKit
import SwiftUI
import SpacemanCore

enum BarEdge {
    case top, bottom
}

/// A borderless panel pinned to the top or bottom of a screen.
///
/// Flush top bars on a notched display sit on `screen.frame` so they fill the
/// ears either side of the camera; everything else uses `visibleFrame` (menu
/// bar and Dock already subtracted). See `BarPlacement`.
///
/// Everything here is Tier-1 API — an app arranging its own windows is never
/// restricted, sandboxed or not. `.canJoinAllSpaces` is what makes the bar
/// follow the user across Spaces without us knowing or caring which Space is
/// active, and it is the public counterpart to what a private Spaces API would
/// otherwise be used for.
@MainActor
final class BarWindow: NSPanel {

    let edge: BarEdge
    private let thickness: CGFloat
    /// Inset from the screen edges for a floating bar; 0 sits flush and spans
    /// the full width.
    private let margin: CGFloat
    /// Where scroll events go. They arrive here rather than at a view because
    /// nothing inside a bar consumes scroll, so the responder chain delivers
    /// them to the window — see `ZoneScrollRouter`.
    private let router: ZoneScrollRouter

    init<Content: View>(edge: BarEdge, thickness: CGFloat, margin: CGFloat,
                        router: ZoneScrollRouter, content: Content) {
        self.edge = edge
        self.thickness = thickness
        self.margin = margin
        self.router = router

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: thickness),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Never steal focus: clicking a bar control must not deactivate the
        // user's frontmost app.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true

        // Above ordinary windows, below the system menu bar so we never appear
        // to be covering it.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

        collectionBehavior = [
            .canJoinAllSpaces,      // present on every Space
            .stationary,            // don't slide during Mission Control
            .ignoresCycle,          // stay out of Cmd-Tab / Cmd-`
            .fullScreenAuxiliary,   // allowed to sit over full-screen apps
        ]

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    /// Bars are chrome, not windows — they must never become the key window,
    /// or typing would go to them instead of the user's app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private(set) var isHiddenAtEdge = false
    private var restingFrame: CGRect = .zero
    /// The display this bar sits on, so edge reveal applies per display.
    private(set) var displayID: CGDirectDisplayID = 0

    /// Scroll over a bar pages the zone under the pointer.
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        // Vertical only, so a horizontal trackpad swipe across the bar doesn't
        // page it by accident.
        guard abs(delta) > abs(event.scrollingDeltaX) else { return }
        router.scroll(delta: delta, atX: event.locationInWindow.x)
    }

    /// Lay the bar along `edge` of the screen.
    func reposition(on screen: NSScreen, offsetY: CGFloat = 0) {
        displayID = screen.displayID
        let frame = BarPlacement.windowFrame(
            edge: edge == .top ? .top : .bottom,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            thickness: thickness,
            margin: margin,
            offsetY: offsetY)
        restingFrame = frame

        // Don't yank a hidden bar back on screen just because the display
        // geometry changed; only its resting position is updated.
        guard !isHiddenAtEdge else { return }
        guard frame != self.frame else { return }
        setFrame(frame, display: true)
    }

    /// Slide the bar off its edge, or back.
    ///
    /// It slides rather than fading because it is standing in for system chrome
    /// that also slides. The window stays ordered in throughout: `orderOut`
    /// would drop it from the Space and cost a re-add on the way back.
    func setHiddenAtEdge(_ hidden: Bool, animated: Bool = true) {
        guard hidden != isHiddenAtEdge else { return }
        isHiddenAtEdge = hidden

        let target: CGRect
        if hidden {
            // A floating bar has to travel its own margin as well, or it stops
            // with a sliver still showing.
            let travel = thickness + margin
            switch edge {
            case .top:    target = restingFrame.offsetBy(dx: 0, dy: travel)
            case .bottom: target = restingFrame.offsetBy(dx: 0, dy: -travel)
            }
        } else {
            target = restingFrame
        }

        guard animated else {
            setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }

}
