import Foundation

/// An app the user has told Spaceman never to tile, move or resize.
///
/// Stored as JSON in `tiling.excludedApps`, like app shortcuts, so a
/// `defaults read` stays legible and a script can add entries.
public struct ExcludedApp: Codable, Equatable, Identifiable, Sendable {
    /// A bundle identifier (`com.example.Editor`) or, for processes that have
    /// no bundle, an executable name (`example-tool`). A trailing `*` matches
    /// any suffix, so `com.example.*` covers every app from one vendor.
    public var identifier: String
    /// What Settings shows. Not used for matching.
    public var name: String

    public var id: String { identifier }

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

public enum TilingExclusions {

    /// Apple utility surfaces that behave like overlays rather than documents:
    /// single-window, often fixed-size, and expected on top of the desktop
    /// instead of taking a slot in the grid. Ported from the Go version's
    /// `SystemFloatBundles`. Prefix matches, so e.g. every System Settings
    /// extension is covered by its parent. The registered default for
    /// `tiling.excludedApps`, so the user can remove any of them; third-party
    /// apps are never here — what gets tiled is otherwise the user's call.
    public static let defaults: [ExcludedApp] = [
        ExcludedApp(identifier: "com.apple.systempreferences*", name: "System Settings"),
        ExcludedApp(identifier: "com.apple.SystemProfiler*", name: "System Information"),
        ExcludedApp(identifier: "com.apple.ActivityMonitor*", name: "Activity Monitor"),
        ExcludedApp(identifier: "com.apple.AboutThisMacLauncher*", name: "About This Mac"),
        ExcludedApp(identifier: "com.apple.finder.SaveDialog*", name: "Finder Save Dialog"),
        ExcludedApp(identifier: "com.apple.KeychainAccess*", name: "Keychain Access"),
        ExcludedApp(identifier: "com.apple.ScreenSharing*", name: "Screen Sharing"),
        ExcludedApp(identifier: "com.apple.screencaptureui*", name: "Screenshot"),
        ExcludedApp(identifier: "com.apple.controlcenter*", name: "Control Center"),
        ExcludedApp(identifier: "com.apple.notificationcenterui*", name: "Notification Center"),
        ExcludedApp(identifier: "com.apple.PhotoBooth*", name: "Photo Booth"),
        ExcludedApp(identifier: "com.apple.Dictionary*", name: "Dictionary"),
        ExcludedApp(identifier: "com.apple.calculator*", name: "Calculator"),
        ExcludedApp(identifier: "com.apple.ColorSyncUtility*", name: "ColorSync Utility"),
        ExcludedApp(identifier: "com.apple.AirPortBaseStationAgent*", name: "AirPort Base Station Agent"),
        ExcludedApp(identifier: "com.apple.print*", name: "Print Dialogs & Printer Setup"),
        ExcludedApp(identifier: "com.apple.DiskUtility*", name: "Disk Utility"),
        ExcludedApp(identifier: "com.apple.audio.AudioMIDISetup*", name: "Audio MIDI Setup"),
        ExcludedApp(identifier: "com.apple.appkit.xpc.openAndSavePanelService*", name: "Open & Save Panels"),
        ExcludedApp(identifier: "com.apple.SecurityAgent*", name: "Security Agent"),
        ExcludedApp(identifier: "com.apple.coreservices.uiagent*", name: "CoreServices UI Agent"),
        ExcludedApp(identifier: "com.apple.UserNotificationCenter*", name: "User Notification Center"),
    ]

    /// Whether a process is excluded, given every name it goes by: its bundle
    /// ID, the bundle IDs of any apps it is nested inside, and its executable
    /// name. An entry matches if it fits any one of them.
    public static func isExcluded(_ list: [ExcludedApp], identities: [String]) -> Bool {
        list.contains { entry in
            identities.contains { matches(entry.identifier, $0) }
        }
    }

    public static func isExcluded(_ list: [ExcludedApp],
                                  bundleID: String?, processName: String?) -> Bool {
        isExcluded(list, identities: [bundleID, processName].compactMap { $0 })
    }

    /// The `.app` bundles enclosing `bundlePath`, innermost first, excluding
    /// the bundle itself. Some apps run their UI from an app nested inside the
    /// one the user installed (`Outer.app/Contents/MacOS/Inner.app`), each
    /// with its own bundle ID, and the user only knows the outer one.
    public static func enclosingAppPaths(of bundlePath: String) -> [String] {
        var components = bundlePath.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        var result: [String] = []
        components.removeLast()
        while !components.isEmpty {
            if components.last?.hasSuffix(".app") == true {
                result.append(components.joined(separator: "/"))
            }
            components.removeLast()
        }
        return result
    }

    /// Case-insensitive; a trailing `*` makes the rest a prefix. Bundle IDs are
    /// case-insensitive in LaunchServices, and nobody types them carefully.
    public static func matches(_ pattern: String, _ candidate: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        let candidate = candidate.lowercased()
        guard !pattern.isEmpty, pattern != "*" else { return false }
        if pattern.hasSuffix("*") {
            return candidate.hasPrefix(String(pattern.dropLast()))
        }
        return candidate == pattern
    }

    /// A corrupt value degrades to an empty list, never to an error.
    public static func decode(_ json: String) -> [ExcludedApp] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([ExcludedApp].self, from: data)
        else { return [] }
        return list
    }

    public static func encode(_ list: [ExcludedApp]) -> String {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}
