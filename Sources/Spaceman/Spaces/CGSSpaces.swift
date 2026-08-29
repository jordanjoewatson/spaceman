import CoreGraphics
import Foundation

/// Space membership and identity from the private SkyLight APIs — the same
/// calls the Go version makes (`internal/core/store/native_darwin.c`).
///
/// Resolved with `dlsym` rather than linked: these symbols are private but have
/// been stable for decades, and dynamic resolution means a surprise absence
/// degrades to "no space information" instead of a dyld crash at launch.
///
/// Exact space tags are what make Space transitions clean: a window is tiled
/// only when its tag says it is on a Space that is currently visible, so the
/// compositing overlap during a Space slide — where both Spaces' windows
/// briefly report on-screen geometry — never produces a mixed window set.
@MainActor
final class CGSSpaces {

    static let shared = CGSSpaces()

    /// False when the SkyLight symbols could not be resolved; callers fall back
    /// to geometry-only heuristics in that case.
    let isAvailable: Bool

    private let mainConnectionID: @convention(c) () -> CInt
    private let getActiveSpace: @convention(c) (CInt) -> UInt64
    private let copySpacesForWindows: @convention(c) (CInt, CInt, CFArray) -> Unmanaged<CFArray>?
    private let copyManagedDisplaySpaces: @convention(c) (CInt) -> Unmanaged<CFArray>?
    /// Optional: per-display UUIDs for matching display dicts to screens.
    /// Absent means per-display resolution degrades to the global active Space.
    private let createDisplayUUID: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?)?

    private init() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if let mainSym = sky.flatMap({ dlsym($0, "CGSMainConnectionID") }),
           let activeSym = dlsym(sky, "CGSGetActiveSpace"),
           let windowsSym = dlsym(sky, "CGSCopySpacesForWindows"),
           let displaysSym = dlsym(sky, "CGSCopyManagedDisplaySpaces") {
            isAvailable = true
            mainConnectionID = unsafeBitCast(mainSym, to: (@convention(c) () -> CInt).self)
            getActiveSpace = unsafeBitCast(activeSym, to: (@convention(c) (CInt) -> UInt64).self)
            copySpacesForWindows = unsafeBitCast(windowsSym, to: (@convention(c) (CInt, CInt, CFArray) -> Unmanaged<CFArray>?).self)
            copyManagedDisplaySpaces = unsafeBitCast(displaysSym, to: (@convention(c) (CInt) -> Unmanaged<CFArray>?).self)
        } else {
            isAvailable = false
            mainConnectionID = { 0 }
            getActiveSpace = { _ in 0 }
            copySpacesForWindows = { _, _, _ in nil }
            copyManagedDisplaySpaces = { _ in nil }
        }
        // Modern macOS implements this in SkyLight (CoreGraphics re-exports it).
        createDisplayUUID = sky
            .flatMap { dlsym($0, "CGDisplayCreateUUIDFromDisplayID") }
            .map { unsafeBitCast($0, to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?).self) }
    }

    /// The active Space (the one receiving input), or nil when unavailable.
    func activeSpace() -> UInt64? {
        guard isAvailable else { return nil }
        let id = getActiveSpace(mainConnectionID())
        return id == 0 ? nil : id
    }

    /// The Space currently shown on each display, keyed by CoreGraphics
    /// display id. With "Displays have separate Spaces" (the default) every
    /// display has its own current Space, and each display's bar and layout
    /// memory key off this.
    func currentSpacesByDisplay() -> [CGDirectDisplayID: UInt64] {
        guard isAvailable,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue()
                  as? [[String: Any]]
        else { return [:] }

        var result: [CGDirectDisplayID: UInt64] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let space = Self.spaceID(from: current),
                  let displayID = displayID(forIdentifier: identifier)
            else { continue }
            result[displayID] = space
        }
        return result
    }

    /// Display dicts name themselves by UUID ("Main" on older systems); match
    /// against `CGDisplayCreateUUIDFromDisplayID` per online display.
    private func displayID(forIdentifier identifier: String) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }
        guard let createDisplayUUID else { return nil }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        for id in ids {
            guard let uuid = createDisplayUUID(id)?.takeRetainedValue() else { continue }
            if CFUUIDCreateString(nil, uuid) as String == identifier { return id }
        }
        return nil
    }

    /// User Spaces on each display, in Mission Control order.
    ///
    /// Full-screen and system Spaces (`type != 0`) are omitted — the same
    /// filter the Go version's `store_spaces` uses for the workspace dots.
    func userSpacesByDisplay() -> [CGDirectDisplayID: [UInt64]] {
        guard isAvailable,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue()
                  as? [[String: Any]]
        else { return [:] }

        var result: [CGDirectDisplayID: [UInt64]] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let displayID = displayID(forIdentifier: identifier),
                  let spaces = display["Spaces"] as? [[String: Any]]
            else { continue }
            result[displayID] = spaces.compactMap { space in
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                guard type == 0 else { return nil }
                return Self.spaceID(from: space)
            }
        }
        return result
    }

    /// The Space currently shown on each display, across all displays.
    ///
    /// With "Displays have separate Spaces" every display shows its own Space,
    /// and tiling must treat all of them as visible — matching the Go region
    /// model (one region per display × Space) without needing to know which
    /// Space is on which display.
    func visibleSpaces() -> Set<UInt64> {
        guard isAvailable,
              let displays = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue()
                  as? [[String: Any]]
        else { return [] }

        var result = Set<UInt64>()
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any],
                  let id = Self.spaceID(from: current) else { continue }
            result.insert(id)
        }
        return result
    }

    /// Space membership for a batch of windows (mask 7 = all spaces).
    /// Windows CGS does not know are absent from the result.
    func spaces(for windowIDs: [CGWindowID]) -> [CGWindowID: Set<UInt64>] {
        guard isAvailable, !windowIDs.isEmpty else { return [:] }
        let cid = mainConnectionID()

        let query = windowIDs.map { NSNumber(value: $0) } as CFArray
        let spaces = copySpacesForWindows(cid, 7, query)?.takeRetainedValue() as? [NSNumber] ?? []

        var result: [CGWindowID: Set<UInt64>] = [:]
        if spaces.count == windowIDs.count {
            // One space id per queried window, positionally.
            for (id, space) in zip(windowIDs, spaces) {
                result[id, default: []].insert(space.uint64Value)
            }
        } else {
            // Shape not as expected — fall back to the Go version's exact
            // per-window call rather than guess at the mapping.
            for id in windowIDs {
                let one = [NSNumber(value: id)] as CFArray
                guard let list = copySpacesForWindows(cid, 7, one)?.takeRetainedValue() as? [NSNumber],
                      let first = list.first else { continue }
                result[id, default: []].insert(first.uint64Value)
            }
        }
        return result
    }

    private static func spaceID(from dict: [String: Any]) -> UInt64? {
        if let n = dict["id64"] as? NSNumber { return n.uint64Value }
        if let n = dict["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        return nil
    }
}
