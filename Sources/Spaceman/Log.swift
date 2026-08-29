import Foundation

/// Opt-in diagnostics: `SPACEMAN_DEBUG=1 ./Spaceman.app/Contents/MacOS/Spaceman`
///
/// The tiling path has no visible output when it decides to do nothing, which
/// makes "nothing happened" impossible to tell apart from "nothing needed to
/// happen". This makes that decision observable.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["SPACEMAN_DEBUG"] == "1"

    private static let start = Date()

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        // Milliseconds since launch: latency questions ("how long after I moved
        // a window did it snap back?") are the main thing this log answers, and
        // wall-clock timestamps make that arithmetic harder, not easier.
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        FileHandle.standardError.write(Data("[spaceman +\(ms)ms] \(message())\n".utf8))
    }
}
