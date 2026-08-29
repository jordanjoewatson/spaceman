import AppKit
@preconcurrency import ApplicationServices
import Foundation
import SpacemanCore

enum MoverError: Error, LocalizedError {
    case accessibilityNotGranted
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility access not granted — enable Spaceman in "
                 + "System Settings → Privacy & Security → Accessibility"
        case .failed(let detail):
            return "Move failed: \(detail)"
        }
    }
}

/// The single seam between "decide where windows go" and "actually move them".
///
/// Everything above this protocol is pure and portable; everything that needs
/// privilege is below it.
@MainActor
protocol WindowMover: AnyObject {
    /// Human-readable name for the status bar.
    var name: String { get }
    /// False when the mover exists but cannot act right now (Accessibility
    /// consent not granted or revoked). The app must stay usable in this state.
    var isReady: Bool { get }
    /// Whether frames can be applied at display rate. Only movers with a direct,
    /// in-process path qualify; anything crossing an IPC boundary per frame must
    /// snap instead, or animation costs more than it is worth.
    var supportsAnimation: Bool { get }
    func apply(_ moves: [Move]) throws
    /// Apply one intermediate animation frame. Best-effort and latency-
    /// sensitive: correctness is the final `apply`'s job, so implementations
    /// should favour speed here.
    func applyFrame(_ moves: [Move]) throws
    /// Drop any cached state for windows that no longer exist.
    func retain(only live: Set<CGWindowID>)
}

extension WindowMover {
    /// Movers that cannot animate never receive intermediate frames, so the
    /// default simply forwards.
    func applyFrame(_ moves: [Move]) throws { try apply(moves) }
    /// Most movers hold no per-window state.
    func retain(only live: Set<CGWindowID>) {}
}

// MARK: - Accessibility

/// Direct AX window control — the only mover.
///
/// `AXUIElementSetAttributeValue` on another app's window requires Accessibility
/// consent; that is the single permission this app needs. Consent is requested
/// once at launch (`requestConsentIfNeeded`); afterwards `isReady` simply
/// reflects `AXIsProcessTrusted()`.
@MainActor
final class AccessibilityMover: WindowMover {
    let name = "Accessibility"

    var isReady: Bool { AXIsProcessTrusted() }

    /// AX writes are direct and cheap enough to drive at 60 Hz — but only with
    /// `elementCache` below.
    let supportsAnimation = true

    /// CGWindowID -> AX element.
    ///
    /// Resolving an element means creating an application element and copying
    /// its entire window list, which is several IPC round-trips. Doing that per
    /// window per frame at 60 Hz is what turns a smooth animation into the very
    /// lag it was meant to remove, so resolved elements are kept. A write that
    /// fails against a cached element drops the entry and re-resolves once
    /// (`retryFailed`), and `retain(only:)` prunes entries for closed windows.
    private var elementCache: [CGWindowID: AXUIElement] = [:]
    private let resolver = AXWindowResolver()

    /// Frame writes run here, never on the main thread.
    ///
    /// An AX write is a synchronous round-trip and a slow app can take tens of
    /// milliseconds. Doing that inline blocked the main thread for the whole
    /// batch — measured at 158ms for four windows — which stalls the timer, the
    /// bars and every click for the duration. Serial, so batches still land in
    /// the order they were issued; parallel *within* a batch so windows move
    /// together.
    private let writeQueue = DispatchQueue(label: "com.spaceman.axwrite", qos: .userInteractive)
    /// True while a batch is outstanding. Frames arriving meanwhile are dropped
    /// rather than queued: a backlog would make the animation finish late and
    /// then keep replaying stale frames.
    private var batchInFlight = false

    func requestConsentIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func apply(_ moves: [Move]) throws {
        guard isReady else { throw MoverError.accessibilityNotGranted }
        // Final placement: size, position, size again — the order the Go
        // version settled on. Apps with minimum sizes can clamp a resize, and
        // terminals snap to character-cell increments; the second size write
        // lands the window on the best frame it will actually accept.
        write(moves, reassertSize: true)
    }

    func applyFrame(_ moves: [Move]) throws {
        guard isReady else { throw MoverError.accessibilityNotGranted }
        // Drop this frame if the previous batch is still going. The animation is
        // driven by elapsed time, not frame count, so a dropped frame costs
        // smoothness and nothing else — it still lands on target, on schedule.
        guard !batchInFlight else { return }
        // Intermediate frame: two writes rather than three. The size fix-up
        // only matters at the destination, and dropping it removes a third of
        // the per-frame IPC.
        write(moves, reassertSize: false)
    }

    /// One window's frame write, safe to hand to another thread.
    ///
    /// `@unchecked Sendable` is accurate rather than a suppression: `AXUIElement`
    /// is an immutable CoreFoundation type, the Accessibility API is safe to
    /// call from any thread, and each element addresses a *different* process,
    /// so no two iterations touch the same remote object.
    private struct FrameWrite: @unchecked Sendable {
        let windowID: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let rect: CGRect
    }

    /// Collects per-window write failures from the concurrent batch without a
    /// data race, so they can be retried back on the main actor.
    private final class WriteFailures: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [FrameWrite] = []
        func append(_ write: FrameWrite) {
            lock.lock()
            writes.append(write)
            lock.unlock()
        }
    }

    private func write(_ moves: [Move], reassertSize: Bool) {
        let targets: [FrameWrite] = moves.compactMap { move in
            guard let element = cachedElement(for: move.window) else { return nil }
            return FrameWrite(windowID: move.window.id, pid: move.window.pid,
                              element: element, rect: Coordinates.toQuartz(move.target))
        }
        guard !targets.isEmpty else { return }

        batchInFlight = true
        writeQueue.async { [weak self] in
            let failures = WriteFailures()
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let target = targets[index]
                if !Self.writeFrame(target.element, rect: target.rect, reassertSize: reassertSize) {
                    failures.append(target)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.batchInFlight = false
                    self.retryFailed(failures.writes, reassertSize: reassertSize)
                }
            }
        }
    }

    /// Write one frame to one element. Returns false when any setter failed.
    ///
    /// The result is checked so a dead element (window closed, app restarted
    /// and re-created its AX tree) is noticed instead of absorbing writes
    /// silently forever.
    private nonisolated static func writeFrame(_ element: AXUIElement, rect: CGRect, reassertSize: Bool) -> Bool {
        var origin = rect.origin
        var size = rect.size
        var ok = true

        if let value = AXValueCreate(.cgSize, &size) {
            ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success && ok
        }
        if let value = AXValueCreate(.cgPoint, &origin) {
            ok = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success && ok
        }
        if reassertSize, let value = AXValueCreate(.cgSize, &size) {
            ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success && ok
        }
        return ok
    }

    /// A write against a cached element failed: drop the entry, re-resolve the
    /// window once, and retry the write once. If re-resolution finds nothing,
    /// the window is gone and the next enumeration will forget it.
    private func retryFailed(_ failures: [FrameWrite], reassertSize: Bool) {
        for failure in failures {
            elementCache[failure.windowID] = nil
            guard let element = resolver.windowElement(pid: failure.pid, id: failure.windowID) else { continue }
            elementCache[failure.windowID] = element

            // FrameWrite is @unchecked Sendable, so capturing it is race-free.
            let retry = FrameWrite(windowID: failure.windowID, pid: failure.pid,
                                   element: element, rect: failure.rect)
            writeQueue.async {
                _ = Self.writeFrame(retry.element, rect: retry.rect, reassertSize: reassertSize)
            }
        }
    }

    private func cachedElement(for window: ManagedWindow) -> AXUIElement? {
        if let cached = elementCache[window.id] { return cached }
        guard let resolved = resolver.windowElement(pid: window.pid, id: window.id) else { return nil }
        elementCache[window.id] = resolved
        return resolved
    }

    /// Drop cache entries for windows that no longer exist, so the dictionary
    /// cannot grow without bound over a long session.
    func retain(only live: Set<CGWindowID>) {
        elementCache = elementCache.filter { live.contains($0.key) }
    }
}

@MainActor
enum MoverFactory {
    static func makeDefault() -> WindowMover {
        let mover = AccessibilityMover()
        mover.requestConsentIfNeeded()
        return mover
    }
}
