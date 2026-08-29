import AppKit
import SpacemanCore

/// Focus-follows-mouse: the window under the pointer takes keyboard focus after
/// it has been there long enough to look deliberate.
///
/// Off by default and toggled from the status menu. The Go version's rules are
/// kept because each one exists to stop it firing when you did not mean it:
///
/// - a **dwell** before switching, so crossing a window on the way somewhere
///   else does not steal focus from what you were typing into;
/// - **no raise**, so the window takes the keyboard without jumping above the
///   one you were reading;
/// - **suspended while a mouse button is down**, so a drag that crosses a
///   window boundary — resizing, selecting text, dragging a file — does not
///   move focus out from under the drag.
@MainActor
final class MouseFocus {

    private let preferences: Preferences
    /// The frames the layout intends, and the pid to focus for each window.
    private let targets: () -> [(id: CGWindowID, pid: pid_t, frame: CGRect)]

    private var timer: Timer?
    /// The window the pointer has been over, and since when. A candidate has to
    /// hold still for the dwell before it is acted on.
    private var candidate: CGWindowID?
    private var candidateSince = Date.distantPast
    /// The last window this actually focused, so a window that already has focus
    /// is never re-focused on every poll.
    private var lastFocused: CGWindowID?

    init(preferences: Preferences,
         targets: @escaping () -> [(id: CGWindowID, pid: pid_t, frame: CGRect)]) {
        self.preferences = preferences
        self.targets = targets
    }

    deinit {
        timer?.invalidate()
    }

    var isEnabled: Bool {
        get { preferences[Defaults.followMouse] }
        set {
            preferences[Defaults.followMouse] = newValue
            sync()
        }
    }

    /// Start or stop polling to match the preference. Called at launch and
    /// whenever the setting changes, from either the menu or `defaults write`.
    func sync() {
        isEnabled ? start() : stop()
    }

    private func start() {
        guard timer == nil else { return }
        // 35 Hz, as in Go. The work is a pointer read and a rect test; the poll
        // has to out-pace the pointer or a quick flick between windows is missed.
        let timer = Timer(timeInterval: 1.0 / 35.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        candidate = nil
        lastFocused = nil
    }

    private func tick() {
        // A held button means a drag is in progress; moving focus out from under
        // it would break the drag.
        guard NSEvent.pressedMouseButtons == 0 else {
            candidate = nil
            return
        }

        let pointer = NSEvent.mouseLocation
        guard let window = windowUnder(pointer) else {
            candidate = nil
            return
        }

        // Already focused, or already the candidate we are timing.
        guard window.id != lastFocused else { return }
        if candidate != window.id {
            candidate = window.id
            candidateSince = Date()
            return
        }

        let dwell = preferences[Defaults.hoverSeconds]
        guard Date().timeIntervalSince(candidateSince) >= dwell else { return }

        lastFocused = window.id
        candidate = nil
        WindowFocus.focusWithoutRaise(pid: window.pid, id: window.id)
    }

    /// The topmost tiled window containing the pointer.
    ///
    /// Reverse order because `plannedTargets` reports the layout's slot order
    /// and a zoomed window is drawn over the rest — the later entry wins, which
    /// matches what the user can actually see and click.
    private func windowUnder(_ point: CGPoint) -> (id: CGWindowID, pid: pid_t)? {
        for window in targets().reversed() where window.frame.contains(point) {
            return (window.id, window.pid)
        }
        return nil
    }
}
