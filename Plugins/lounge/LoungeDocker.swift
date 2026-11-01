import Foundation

/// Runs Docker Compose for `.dockerCompose` entries.
///
/// No shell is involved: `docker` is found at a fixed set of install
/// locations and run through `Process` with a fixed argument array. The only
/// variable argument is the compose file path, which was picked in a file
/// dialog, validated, and is passed as one argument.
enum LoungeDocker {

    /// Where Docker Desktop, Homebrew, OrbStack and Colima put the CLI.
    static let candidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
        NSHomeDirectory() + "/.docker/bin/docker",
        NSHomeDirectory() + "/.orbstack/bin/docker",
    ]

    static func executable() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum Action { case up, down }

    static func arguments(file: String, _ action: Action) -> [String] {
        switch action {
        case .up: return ["compose", "-f", file, "up", "-d"]
        case .down: return ["compose", "-f", file, "down"]
        }
    }

    /// The exact command, as shown in the first-launch confirmation.
    static func commandLine(file: String, _ action: Action) -> String {
        (["docker"] + arguments(file: file, action).map { $0.contains(" ") ? "\"\($0)\"" : $0 })
            .joined(separator: " ")
    }

    struct Failure: Error { let message: String }

    /// Runs `docker compose … <action>` and returns once it exits. `up -d`
    /// returns when containers are started (it may pull and build first).
    static func run(file: String, _ action: Action,
                    progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard let docker = executable() else {
            throw Failure(message: "Docker isn't installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = arguments(file: file, action)
        process.currentDirectoryURL = URL(fileURLWithPath: file).deletingLastPathComponent()
        // Compose finds its credential helpers and plugins on PATH; an agent
        // app launched from Finder has a minimal one.
        var environment = ProcessInfo.processInfo.environment
        let dockerDir = (docker as NSString).deletingLastPathComponent
        environment["PATH"] = [dockerDir, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
            .joined(separator: ":")
        process.environment = environment
        // Compose reports progress (pulls, build steps) on stderr. The last
        // line is kept for the error message and passed on as progress.
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        let lastLine = LastLine()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty }) else { return }
            lastLine.set(line)
            progress?(line)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                errorPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let text = lastLine.get() ?? "exit \(process.terminationStatus)"
                    continuation.resume(throwing: Failure(message: text))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private final class LastLine: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ line: String) { lock.lock(); value = line; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Synchronous `down`, for app shutdown.
    static func downBlocking(file: String) {
        guard let docker = executable() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = arguments(file: file, .down)
        process.currentDirectoryURL = URL(fileURLWithPath: file).deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Polls `http://localhost:<port>` until anything answers, or gives up.
    /// Whether Spaceman may read the project's folder.
    ///
    /// `docker` inherits Spaceman's privacy permissions, so a project under
    /// ~/Documents, ~/Desktop or ~/Downloads fails with "operation not
    /// permitted" until Spaceman has access. Reading the folder from Spaceman
    /// itself is what makes macOS show its "would like to access files in
    /// your Documents folder" prompt, which a child process never triggers.
    static func canReadProject(file: String) -> Bool {
        let folder = (file as NSString).deletingLastPathComponent
        return (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
            && FileManager.default.isReadableFile(atPath: file)
    }

    static let accessHelp = "Spaceman can't read this project's folder. Allow it in System Settings → "
        + "Privacy & Security → Files & Folders (or Full Disk Access)."

    /// How many of the project's containers are running, or nil if Docker
    /// couldn't be asked. Sees stacks started outside Lounge too.
    static func runningCount(file: String) async -> Int? {
        guard let docker = executable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["compose", "-f", file, "ps", "--status", "running", "--quiet"]
        process.currentDirectoryURL = URL(fileURLWithPath: file).deletingLastPathComponent()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                continuation.resume(returning: lines.count)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    static func waitForPort(_ port: Int, timeout: TimeInterval = 180) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        while Date() < deadline {
            if (try? await URLSession.shared.data(for: request)) != nil { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}
