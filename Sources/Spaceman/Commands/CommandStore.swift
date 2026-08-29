import AppKit
import SpacemanCore

/// Loads user-defined commands from a JSON file and watches it for edits.
///
/// The file lives in the app's own Application Support directory — created on
/// first launch, no prompts. Hand-edited: the scripts it holds are listed
/// on the ⌃⌥H sheet and run through `spaceman://run/<name>`.
@MainActor
final class CommandStore {

    private(set) var set = CommandSet(scripts: [], problems: [])
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    /// Called after a successful reload so the UI can rebuild.
    var onChange: ((CommandSet) -> Void)?
    /// Called with a human-readable problem so it can surface in the bar.
    var onProblem: ((String) -> Void)?

    /// `~/Library/Application Support/Spaceman/commands.json`.
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Spaceman", isDirectory: true)
                   .appendingPathComponent("commands.json")
    }

    func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeTemplate(to: url)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try CommandSet.decode(from: data)
            set = decoded
            Log.debug("loaded \(decoded.scripts.count) command(s) from \(url.path)")
            for problem in decoded.problems { onProblem?(problem) }
            onChange?(decoded)
        } catch {
            // Keep the previously loaded commands: a half-saved file should not
            // wipe out what was already working.
            Log.debug("commands.json failed to load: \(error)")
            onProblem?("commands.json: \(error.localizedDescription)")
        }
    }

    /// Reload whenever the file is written, so editing it takes effect without
    /// restarting the app.
    func startWatching() {
        stopWatching()
        let url = Self.fileURL
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Editors commonly replace rather than rewrite, which invalidates
                // the descriptor — re-arm on anything but a plain write.
                self.load()
                self.startWatching()
            }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    func stopWatching() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Write a starter file the first time, so the feature is discoverable
    /// instead of being a documented path nobody finds.
    private func writeTemplate(to url: URL) {
        let template = """
        {
          "_comment": [
            "Spaceman custom commands. Each entry is a name and a list of steps.",
            "Steps are built-in verbs, not shell commands - see README.",
            "Verbs: layout <master|bsp|columns|rows|monocle|next>, retile,",
            "       master <0.2-0.8> or master <+/-delta>, gap <0-200>,",
            "       animation <on|off>",
            "Run one from the menu-bar item, or: open 'spaceman://run/coding'"
          ],
          "commands": {
            "coding":  ["layout master", "master 0.65", "gap 8", "retile"],
            "review":  ["layout columns", "gap 16", "retile"],
            "focus":   ["layout monocle", "animation off", "retile"]
          }
        }
        """
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(template.utf8).write(to: url, options: .atomic)
            Log.debug("wrote starter commands.json to \(url.path)")
            load()
        } catch {
            Log.debug("could not write starter commands.json: \(error)")
        }
    }
}
