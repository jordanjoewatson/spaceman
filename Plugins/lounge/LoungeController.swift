import AppKit
import ApplicationServices
import PluginKit
import WebKit

/// One tile on the home screen.
enum LoungeTile: Equatable, Identifiable {
    case entry(LoungeEntry)
    case add
    case exit
    case suggestion(LoungeApps.Installed)

    var id: String {
        switch self {
        case let .entry(e): return "entry.\(e.id)"
        case .add: return "add"
        case .exit: return "exit"
        case let .suggestion(app): return "suggest.\(app.bundleID)"
        }
    }
}

/// Lounge's state and navigation: which screen is up, what has focus, and
/// what is running. Input arrives as `LoungeInput` from the gamepad or the
/// keyboard fallback.
@MainActor
final class LoungeController: ObservableObject {

    static let sceneID = "lounge.home"

    enum Screen: Equatable {
        case home
        /// Lounge's own web view, showing a running web entry.
        case web
        /// The controller-driven "Add" picker of installed apps.
        case addPicker
        /// Asking whether to remove this entry from the library.
        case confirmRemove(LoungeEntry)
        /// First launch of a process-backed entry: shows exactly what will run.
        case confirmLaunch(LoungeEntry)
        /// An entry is starting; its progress text is in `starting`.
        case starting(LoungeEntry)
    }

    @Published private(set) var screen: Screen = .home
    @Published var focusRow = 0
    @Published var focusColumn = 0
    @Published var pickerIndex = 0
    /// The web entry currently loaded in `webView`, if any.
    @Published private(set) var webEntryID: UUID?
    /// Bumped when apps launch or quit, so running badges refresh.
    @Published private(set) var runningGeneration = 0
    /// Compose projects Lounge has brought up and not yet taken down.
    @Published private(set) var composeRunning: [UUID: String] = [:]
    /// Entries part-way through launching, with what they're waiting for.
    /// Launching an entry that's already here just shows its progress, so a
    /// second press can't start it twice.
    @Published private(set) var starting: [UUID: String] = [:]

    enum Status { case off, starting, running }

    func status(of entry: LoungeEntry) -> Status {
        if starting[entry.id] != nil { return .starting }
        return isRunning(entry) ? .running : .off
    }

    let store: LoungeStore
    private let host: any PluginHost
    private(set) var webView: WKWebView?
    private var installed: [LoungeApps.Installed] = []
    /// What Home returns to: the app that was frontmost when Lounge opened.
    private var returnApp: NSRunningApplication?
    private var observers: [NSObjectProtocol] = []
    /// NSCursor.hide/unhide must be balanced.
    private var cursorHidden = false

    init(store: LoungeStore, host: any PluginHost) {
        self.store = store
        self.host = host
    }

    var isVisible: Bool { host.isSceneVisible(Self.sceneID) }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningGeneration += 1 }
            })
        }
        // Ask for folder access now, while the desktop is visible: macOS's
        // prompt would otherwise appear behind Lounge's fullscreen window.
        for entry in store.entries {
            if case let .dockerCompose(file, _, _) = entry.launch { _ = LoungeDocker.canReadProject(file: file) }
        }
        // Launched apps stay out of tiling for as long as they're in the library.
        for id in store.entries.compactMap(\.bundleID) { host.setTilingExempt(bundleID: id, true) }
    }

    func stop() {
        // Leave no containers behind when Spaceman quits.
        for entry in store.entries {
            guard case let .dockerCompose(file, _, false) = entry.launch,
                  composeRunning[entry.id] != nil else { continue }
            LoungeDocker.downBlocking(file: file)
        }
        composeRunning.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    // MARK: - Tiles

    var mainRow: [LoungeTile] { store.entries.map(LoungeTile.entry) + [.add, .exit] }

    /// Shown only while the library is empty: installed games, read-only.
    var suggestedRow: [LoungeTile] {
        guard store.entries.isEmpty else { return [] }
        return installed.filter(\.isGame).prefix(8).map(LoungeTile.suggestion)
    }

    var rows: [[LoungeTile]] { [mainRow, suggestedRow].filter { !$0.isEmpty } }

    var focusedTile: LoungeTile? {
        let rows = self.rows
        guard rows.indices.contains(focusRow), rows[focusRow].indices.contains(focusColumn) else { return nil }
        return rows[focusRow][focusColumn]
    }

    /// Picker list: games first, then everything else, minus what's added.
    var pickerApps: [LoungeApps.Installed] {
        let available = installed.filter { !store.contains(bundleID: $0.bundleID) }
        return available.filter(\.isGame) + available.filter { !$0.isGame }
    }

    func isRunning(_ entry: LoungeEntry) -> Bool {
        _ = runningGeneration
        switch entry.launch {
        case let .app(bundleID, _):
            return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        case .web:
            return webEntryID == entry.id
        case .dockerCompose:
            return composeRunning[entry.id] != nil
        }
    }

    // MARK: - Showing and hiding

    func toggle() {
        if isVisible { returnFromHome() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            returnApp = front
        }
        installed = LoungeApps.scan()
        if screen == .addPicker { screen = .home }
        if screen == .web { screen = .home }
        clampFocus()
        host.showScene(Self.sceneID)
        refreshComposeStatus()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshComposeStatus() }
        }
        // A 10-foot screen has no use for the pointer.
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }

    /// Home pressed inside Lounge: back to whatever was running.
    private func returnFromHome() {
        // In the web view, Home goes to Lounge's home screen (the page keeps
        // running); from there, Home goes back to the page.
        if screen != .home { screen = .home; return }
        if webEntryID != nil, returnApp == nil {
            screen = .web
            return
        }
        hide()
        returnApp?.activate()
    }

    /// "Exit Lounge": close it and leave the desktop as normal.
    func exitLounge() {
        returnApp = nil
        screen = .home
        hide()
    }

    /// Re-reads which compose stacks are up, including ones started outside
    /// Lounge, so their dots are right. Runs on show and every few seconds
    /// while Lounge is visible.
    func refreshComposeStatus() {
        loungeLog.info("refreshing compose status, docker=\(LoungeDocker.executable() ?? "none", privacy: .public)")
        for entry in store.entries {
            guard case let .dockerCompose(file, _, _) = entry.launch, starting[entry.id] == nil,
                  LoungeDocker.canReadProject(file: file) else { continue }
            Task {
                let result = await LoungeDocker.runningCount(file: file)
                loungeLog.info("compose status \(entry.title, privacy: .public): \(result.map(String.init) ?? "nil", privacy: .public)")
                guard let count = result, starting[entry.id] == nil else { return }
                let up = count > 0
                if up != (composeRunning[entry.id] != nil) {
                    composeRunning[entry.id] = up ? file : nil
                }
            }
        }
    }

    private var statusTimer: Timer?

    private func hide() {
        statusTimer?.invalidate()
        statusTimer = nil
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        host.hideScene(Self.sceneID)
    }

    // MARK: - Input

    func handle(_ input: LoungeInput) {
        if input == .home { toggle(); return }
        // Every other button belongs to the game unless Lounge is on screen.
        guard isVisible else { return }

        switch screen {
        case .web:
            handleWeb(input)
        case .addPicker:
            handlePicker(input)
        case let .confirmRemove(entry):
            switch input {
            case .confirm: remove(entry)
            case .back: screen = .home
            default: break
            }
        case let .confirmLaunch(entry):
            switch input {
            case .confirm:
                LoungeLaunchApproval.approve(entry)
                launch(entry)
            case .back: screen = .home
            default: break
            }
        case .starting:
            // Starting can't be cancelled midway; Back just returns home and
            // the page opens when it's ready.
            if input == .back { screen = .home }
        case .home:
            handleHome(input)
        }
    }

    private func handleHome(_ input: LoungeInput) {
        switch input {
        case .left: focusColumn -= 1; clampFocus()
        case .right: focusColumn += 1; clampFocus()
        case .up: focusRow -= 1; clampFocus()
        case .down: focusRow += 1; clampFocus()
        case .confirm: if let tile = focusedTile { activate(tile) }
        case .secondary:
            if case let .entry(entry) = focusedTile, isRunning(entry) { quit(entry) }
        case .hold:
            if case let .entry(entry) = focusedTile { screen = .confirmRemove(entry) }
        case .back, .zoomIn, .zoomOut:
            // Only Home leaves Lounge; Back has nothing to go back to here.
            break
        case .previousSpace: host.switchSpace(.left)
        case .nextSpace: host.switchSpace(.right)
        case .home: break
        }
    }

    /// In a page, every button belongs to the page except the zoom
    /// triggers; only Home leaves it.
    private func handleWeb(_ input: LoungeInput) {
        guard let entryID = webEntryID else { return }
        switch input {
        case .zoomIn: setZoom(zoom(for: entryID) + 0.1, for: entryID)
        case .zoomOut: setZoom(zoom(for: entryID) - 0.1, for: entryID)
        default: break
        }
    }

    /// Per-entry page zoom. Pages sized for big monitors look cramped on a
    /// laptop or a TV at 10 feet, so it's adjustable and remembered.
    static let defaultZoom = 1.0

    func zoom(for id: UUID) -> Double {
        let stored = UserDefaults.standard.double(forKey: "plugin.lounge.zoom.\(id.uuidString)")
        return stored > 0 ? stored : Self.defaultZoom
    }

    private func setZoom(_ value: Double, for id: UUID) {
        let clamped = (min(max(value, 0.5), 2.0) * 10).rounded() / 10
        UserDefaults.standard.set(clamped, forKey: "plugin.lounge.zoom.\(id.uuidString)")
        webView?.pageZoom = clamped
    }

    /// Removes from the library only; a running app keeps running.
    func remove(_ entry: LoungeEntry) {
        store.remove(entry.id)
        libraryRemoved(entry)
        screen = .home
        clampFocus()
    }

    private func handlePicker(_ input: LoungeInput) {
        let apps = pickerApps
        switch input {
        case .up: pickerIndex = max(0, pickerIndex - 1)
        case .down: pickerIndex = min(max(apps.count - 1, 0), pickerIndex + 1)
        case .confirm:
            guard apps.indices.contains(pickerIndex) else { return }
            add(apps[pickerIndex])
            screen = .home
        case .back: screen = .home
        default: break
        }
    }

    func clampFocus() {
        let rows = self.rows
        focusRow = min(max(focusRow, 0), rows.count - 1)
        focusColumn = min(max(focusColumn, 0), rows[focusRow].count - 1)
    }

    // MARK: - Actions

    func activate(_ tile: LoungeTile) {
        switch tile {
        case let .entry(entry): launch(entry)
        case .add:
            pickerIndex = 0
            screen = .addPicker
        case .exit: exitLounge()
        case let .suggestion(app): add(app)
        }
    }

    func add(_ app: LoungeApps.Installed) {
        if store.addApp(at: app.url) {
            host.setTilingExempt(bundleID: app.bundleID, true)
            focusRow = 0
            focusColumn = store.entries.count - 1
        }
        clampFocus()
    }

    func launch(_ entry: LoungeEntry) {
        switch entry.launch {
        case let .app(bundleID, _):
            launchApp(bundleID: bundleID, entry: entry)
        case let .web(url):
            showPage(url, for: entry)
        case let .dockerCompose(file, port, _):
            guard LoungeLaunchApproval.isApproved(entry) else {
                screen = .confirmLaunch(entry)
                return
            }
            let url = URL(string: "http://localhost:\(port)")!
            if starting[entry.id] != nil {
                screen = .starting(entry)
                return
            }
            if composeRunning[entry.id] != nil {
                showPage(url, for: entry)
                return
            }
            guard LoungeDocker.canReadProject(file: file) else {
                loungeLog.error("no access to \(file, privacy: .public)")
                host.note(LoungeDocker.accessHelp)
                return
            }
            starting[entry.id] = "Checking Docker…"
            screen = .starting(entry)
            Task {
                // Only jump to the page if the user is still watching it start.
                let watching = { if case .starting(let shown) = self.screen { return shown.id == entry.id }; return false }
                // Already up (e.g. started outside Lounge): open it as is,
                // rather than running `up` against a live stack.
                if let count = await LoungeDocker.runningCount(file: file), count > 0 {
                    composeRunning[entry.id] = file
                    starting[entry.id] = nil
                    if watching() { showPage(url, for: entry) }
                    return
                }
                starting[entry.id] = "Starting containers…"
                do {
                    try await LoungeDocker.run(file: file, .up) { line in
                        // e.g. "#7 [3/5] RUN pip install …" during a first build.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if self.starting[entry.id] != nil { self.starting[entry.id] = String(line.prefix(120)) }
                            }
                        }
                    }
                    composeRunning[entry.id] = file
                    starting[entry.id] = "Waiting for localhost:\(port)…"
                    let ready = await LoungeDocker.waitForPort(port)
                    starting[entry.id] = nil
                    guard ready else {
                        host.note("\(entry.title) didn't answer on port \(port)")
                        if watching() { screen = .home }
                        return
                    }
                    if watching() { showPage(url, for: entry) }
                } catch {
                    starting[entry.id] = nil
                    let message = (error as? LoungeDocker.Failure)?.message ?? error.localizedDescription
                    loungeLog.error("compose up failed for \(entry.title, privacy: .public): \(message, privacy: .public)")
                    host.note("\(entry.title): \(message)")
                    if watching() { screen = .home }
                }
            }
        }
    }

    /// Loads `url` in Lounge's web view (reusing the page if it's already
    /// this entry's) and shows it.
    private func showPage(_ url: URL, for entry: LoungeEntry) {
        if webEntryID != entry.id {
            let view = webView ?? WKWebView()
            view.pageZoom = zoom(for: entry.id)
            view.load(URLRequest(url: url))
            webView = view
            webEntryID = entry.id
        }
        returnApp = nil
        screen = .web
    }

    private func launchApp(bundleID: String, entry: LoungeEntry) {
        host.setTilingExempt(bundleID: bundleID, true)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            hide()
            running.activate()
            returnApp = running
            return
        }
        guard let url = LoungeApps.url(for: entry) else {
            host.note("\(entry.title) isn't installed")
            return
        }
        guard starting[entry.id] == nil else { return }
        starting[entry.id] = "Opening…"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.starting[entry.id] = nil
                    guard let app, error == nil else {
                        self.host.note("Couldn't open \(entry.title)")
                        return
                    }
                    self.returnApp = app
                    self.hide()
                    LoungeFullscreen.enter(pid: app.processIdentifier)
                }
            }
        }
    }

    func quit(_ entry: LoungeEntry) {
        switch entry.launch {
        case let .app(bundleID, _):
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
                if app == returnApp { returnApp = nil }
            }
        case .web:
            closePage(of: entry)
        case let .dockerCompose(_, _, true):
            // Keep-running stacks: just close the page; the dot stays green.
            closePage(of: entry)
        case let .dockerCompose(file, _, false):
            closePage(of: entry)
            composeRunning[entry.id] = nil
            Task {
                do { try await LoungeDocker.run(file: file, .down) } catch {
                    host.note("\(entry.title): couldn't stop containers")
                }
            }
        }
        runningGeneration += 1
    }

    private func closePage(of entry: LoungeEntry) {
        guard webEntryID == entry.id else { return }
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        webEntryID = nil
    }

    func libraryRemoved(_ entry: LoungeEntry) {
        if let id = entry.bundleID { host.setTilingExempt(bundleID: id, false) }
        if webEntryID == entry.id || composeRunning[entry.id] != nil { quit(entry) }
    }
}

/// Puts a launched app's main window into native fullscreen through the
/// Accessibility API (the permission the tiler already holds). Games that
/// manage their own fullscreen ignore this harmlessly.
enum LoungeFullscreen {
    @MainActor
    static func enter(pid: pid_t, attempt: Int = 0) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement], let window = windows.first {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
            return
        }
        // Windows appear some time after launch; keep trying for ~10s.
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { enter(pid: pid, attempt: attempt + 1) }
        }
    }
}

/// Which process-backed entries the user has approved, and for exactly which
/// command. Changing the entry (a different file) asks again.
enum LoungeLaunchApproval {
    static let key = "plugin.lounge.approvedLaunches"

    /// The command a launch would run, or nil for types that run nothing.
    static func command(for entry: LoungeEntry) -> String? {
        if case let .dockerCompose(file, _, _) = entry.launch {
            return LoungeDocker.commandLine(file: file, .up)
        }
        return nil
    }

    static func isApproved(_ entry: LoungeEntry, defaults: UserDefaults = .standard) -> Bool {
        guard let command = command(for: entry) else { return true }
        return (defaults.stringArray(forKey: key) ?? []).contains(fingerprint(entry.id, command))
    }

    static func approve(_ entry: LoungeEntry, defaults: UserDefaults = .standard) {
        guard let command = command(for: entry) else { return }
        var list = defaults.stringArray(forKey: key) ?? []
        list.append(fingerprint(entry.id, command))
        defaults.set(list, forKey: key)
    }

    private static func fingerprint(_ id: UUID, _ command: String) -> String {
        "\(id.uuidString)|\(command)"
    }
}
