import AppKit
import PluginKit

/// One entry in the launcher's result list. `action` runs when it's selected.
struct LauncherResult {
    let title: String
    let subtitle: String
    let action: @MainActor () -> Void
}

/// Produces results for a query. Providers should return already-ranked,
/// capped results.
@MainActor
protocol LauncherProvider {
    func query(_ q: String) -> [LauncherResult]
    /// Called each time the panel opens, for providers that snapshot their
    /// inputs (a window list is too expensive to rebuild per keystroke).
    func prepareForShow()
}

extension LauncherProvider {
    func prepareForShow() {}
}

/// Ranks results by fuzzy match, less any frecency bonus, and caps them.
/// Fuzzy scores are "lower is better", so a bonus is subtracted: a frequently
/// chosen result wins ties and near-ties, while a precise query still surfaces
/// something never used. Ties keep the providers' original order.
func ranked(_ q: String, _ results: [LauncherResult], limit: Int, uses: Frecency?) -> [LauncherResult] {
    results.enumerated()
        .compactMap { (index, result) -> (index: Int, result: LauncherResult, score: Int)? in
            guard let score = FuzzyMatch.score(q, result.title) else { return nil }
            return (index, result, score - (uses?.score(result.title) ?? 0))
        }
        .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
        .prefix(limit)
        .map(\.result)
}

// MARK: - Calculator

/// Answers arithmetic queries. Anything that doesn't parse yields nothing, so
/// ordinary searches are unaffected.
struct CalcProvider: LauncherProvider {
    func query(_ q: String) -> [LauncherResult] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        // Require a digit and an operator: bare "42" is far more likely to be
        // the start of a search than a sum worth answering.
        guard !trimmed.isEmpty,
              trimmed.contains(where: { "+-*/%^".contains($0) }),
              trimmed.contains(where: { "0123456789".contains($0) })
        else { return [] }
        guard let value = try? CalcEngine.eval(trimmed) else { return [] }
        let text = CalcEngine.format(value)
        return [LauncherResult(title: text, subtitle: "\(trimmed)  ·  press Enter to copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }]
    }
}

// MARK: - Applications

/// Scans the standard application folders once at setup and launches on select.
final class AppProvider: LauncherProvider {
    private let apps: [LauncherResult]
    private let uses: Frecency?

    init(uses: Frecency?) {
        self.uses = uses
        self.apps = AppProvider.scanApps()
    }

    func query(_ q: String) -> [LauncherResult] {
        ranked(q, apps, limit: 8, uses: uses)
    }

    private static func scanApps() -> [LauncherResult] {
        var dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
        dirs.append(NSHomeDirectory() + "/Applications")

        var seen = Set<String>()
        var apps: [LauncherResult] = []

        // Vendors commonly group bundles in a plain folder (PostgreSQL, Adobe,
        // Utilities), so recurse a few levels rather than only reading the top.
        // A .app is itself a directory, so stop descending once we hit one.
        // Symlinked bundles and folders are followed too: Setapp and some
        // installers link into /Applications rather than copying.
        func scan(_ dir: URL, _ depth: Int) {
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            guard let entries else { return }
            for url in entries {
                let name = url.lastPathComponent
                if name.hasSuffix(".app") {
                    let appName = String(name.dropLast(".app".count))
                    guard seen.insert(appName).inserted else { continue }
                    apps.append(LauncherResult(title: appName, subtitle: "Application") {
                        open(url)
                    })
                } else if depth > 0,
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scan(url, depth - 1)
                }
            }
        }
        for dir in dirs { scan(URL(fileURLWithPath: dir), 2) }
        return apps
    }

    /// `createsNewApplicationInstance` opens a new instance/window even when
    /// the app is already running, rather than just reactivating it. Switching
    /// to an already-open app is the window provider's job, not the launcher's.
    private static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("launcher: opening %@: %@", url.lastPathComponent, error.localizedDescription)
            }
        }
    }
}

// MARK: - Open windows

/// Lets the launcher jump to any open window on the current Space.
final class WindowProvider: LauncherProvider {
    private let host: any PluginHost
    private var snapshot: [PluginWindow] = []

    init(host: any PluginHost) {
        self.host = host
    }

    func prepareForShow() {
        snapshot = host.windows
    }

    func query(_ q: String) -> [LauncherResult] {
        var out: [LauncherResult] = []
        for window in snapshot {
            let label = window.title.isEmpty ? window.appName : window.title
            guard FuzzyMatch.matches(q, "\(label) \(window.appName)") else { continue }
            out.append(LauncherResult(title: label, subtitle: "Window · \(window.appName)") {
                [host] in host.focusWindow(window.id)
            })
            if out.count == 8 { break }
        }
        return out
    }
}

// MARK: - Window-manager commands

/// Exposes Spaceman's own window-manager actions as searchable commands.
struct CommandProvider: LauncherProvider {
    let host: any PluginHost

    func query(_ q: String) -> [LauncherResult] {
        host.wmActions.compactMap { action in
            guard FuzzyMatch.matches(q, action.title) else { return nil }
            return LauncherResult(title: action.title, subtitle: "spaceman command",
                                  action: action.action)
        }
    }
}
