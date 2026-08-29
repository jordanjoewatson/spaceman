import AppKit
import Combine
import IOKit.ps
import SpacemanCore

/// Everything the two bars render. One source of truth, mutated only on the
/// main actor, observed by SwiftUI.
@MainActor
final class BarState: ObservableObject {
    /// One dot per user Space on that display, current one marked.
    @Published var spaceDots: [CGDirectDisplayID: [SpaceDot]] = [:]
    /// Split from `date` so the two can be placed in different zones — a preset
    /// may want the time centered and the date off to one side.
    @Published var clock: String = ""
    @Published var date: String = ""
    @Published var battery: BatteryReading?

    /// The layout mode of each display's current Space.
    @Published var layoutModes: [CGDirectDisplayID: LayoutMode] = [:]
    @Published var moverName: String = "—"
    @Published var moverReady: Bool = false
    /// Last error or notice, shown in the bottom bar so failures are visible
    /// rather than silent.
    @Published var status: String = ""

    private var clockTimer: Timer?

    func startClock() {
        updateClock()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func updateClock() {
        let now = Date()
        // Locale-driven rather than a fixed pattern: a bar clock that ignores
        // the user's 24-hour setting is wrong in a way they cannot fix.
        clock = now.formatted(date: .omitted, time: .standard)
        date = now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        battery = BatteryReading.read()
    }

    func note(_ message: String) {
        status = message
        // Clear after a while so a transient failure doesn't look permanent.
        let expected = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.status == expected else { return }
            self.status = ""
        }
    }
}

/// One Space in the bar's dot strip.
struct SpaceDot: Equatable {
    var isCurrent: Bool
}

/// Battery state via `IOPowerSources`. Public, sandbox-safe CoreFoundation API —
/// no entitlement, no consent prompt, and stable for well over a decade.
struct BatteryReading {
    let percent: Int
    let isCharging: Bool
    let isPresent: Bool

    static func read() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            guard let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            return BatteryReading(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: charging,
                isPresent: true
            )
        }
        return nil
    }
}
