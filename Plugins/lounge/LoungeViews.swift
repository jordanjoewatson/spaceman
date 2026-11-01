import AppKit
import SwiftUI
import WebKit

/// The fullscreen home screen, laid out after the user's mockup: the desktop
/// wallpaper behind a top bar, a large greeting top-left, a frosted dock of
/// app tiles near the bottom, and the controller hint bar centred below it.
/// Sizes are proportions of the screen height so it reads the same on a
/// laptop and a TV.
struct LoungeRootView: View {
    @ObservedObject var lounge: LoungeController
    @ObservedObject var store: LoungeStore
    @ObservedObject var gamepad: LoungeGamepad
    @FocusState private var keyboardFocus: Bool
    @State private var wallpaper = LoungeWallpaper.current()

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                background
                switch lounge.screen {
                case .home: home(h: h, width: geo.size.width)
                case .addPicker: LoungeAddPicker(lounge: lounge).padding(.top, h * 0.08)
                case let .confirmRemove(entry):
                    home(h: h, width: geo.size.width).blur(radius: 20)
                    LoungeRemovePrompt(entry: entry, h: h)
                case let .confirmLaunch(entry):
                    home(h: h, width: geo.size.width).blur(radius: 20)
                    LoungeLaunchPrompt(entry: entry, h: h)
                case let .starting(entry):
                    home(h: h, width: geo.size.width).blur(radius: 20)
                    LoungeStartingCard(entry: entry, status: lounge.starting[entry.id] ?? "Starting…", h: h)
                case .web:
                    if let webView = lounge.webView {
                        LoungeWebView(webView: webView).ignoresSafeArea()
                    }
                }
                if lounge.screen != .web {
                    VStack(spacing: 0) {
                        LoungeTopBar(h: h, controllerName: gamepad.controllerName)
                        Spacer()
                    }
                    .padding(.horizontal, h * 0.06)
                }
                // A page gets the whole screen: no hint bar over its bottom edge.
                if lounge.screen != .web {
                    VStack {
                        Spacer()
                        LoungeHintBar(hints: hints, glyphs: gamepad.glyphs, h: h)
                            .padding(.bottom, h * 0.045)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.colorScheme, wallpaper.isDark ? .dark : .light)
        .ignoresSafeArea()
        // Keyboard fallback, so Lounge works (and can be tried) without a pad.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onAppear {
            keyboardFocus = true
            wallpaper = LoungeWallpaper.current()
        }
        .onKeyPress(.leftArrow) { lounge.handle(.left); return .handled }
        .onKeyPress(.rightArrow) { lounge.handle(.right); return .handled }
        .onKeyPress(.upArrow) { lounge.handle(.up); return .handled }
        .onKeyPress(.downArrow) { lounge.handle(.down); return .handled }
        .onKeyPress(.return) { lounge.handle(.confirm); return .handled }
        .onKeyPress(.escape) { lounge.handle(.back); return .handled }
        .onKeyPress(.delete) { lounge.handle(.hold); return .handled }
    }

    @ViewBuilder private var background: some View {
        if let image = wallpaper.image {
            // The screen sets the size; the picture fills it and is cropped.
            // As an overlay on a size-less Color, the image's own dimensions
            // can't leak into the layout (a fill-sized image in the ZStack
            // itself grew the whole screen past the display's edges).
            Color.clear
                .overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill))
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.99, green: 0.93, blue: 0.88),
                                    Color(red: 0.98, green: 0.80, blue: 0.68)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func home(h: CGFloat, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: h * 0.02) {
                Text(greeting)
                    .font(.system(size: h * 0.068, weight: .semibold))
                    .tracking(-h * 0.0012)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: h * 0.032))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, width * 0.06)
            .padding(.top, h * 0.18)

            Spacer()

            if !lounge.suggestedRow.isEmpty {
                VStack(spacing: h * 0.014) {
                    Text("Suggested")
                        .font(.system(size: h * 0.02, weight: .semibold))
                        .textCase(.uppercase).tracking(1.5)
                        .foregroundStyle(.secondary)
                    LoungeDock(lounge: lounge, row: 1, tiles: lounge.suggestedRow, h: h)
                }
                .padding(.bottom, h * 0.05)
            }

            LoungeDock(lounge: lounge, row: 0, tiles: lounge.mainRow, h: h)
                .padding(.bottom, h * 0.19)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "evening" : hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Good \(part)" : "Good \(part), \(first)"
    }

    private var subtitle: String {
        store.entries.isEmpty
            ? "Add a game or app to get started."
            : "Pick up where you left off."
    }

    private var hints: [LoungeHint] {
        switch lounge.screen {
        case .web:
            return []
        case .addPicker:
            return [LoungeHint(\.confirm, "Add"), LoungeHint(\.back, "Cancel")]
        case .confirmRemove:
            return [LoungeHint(\.confirm, "Remove"), LoungeHint(\.back, "Cancel")]
        case .confirmLaunch:
            return [LoungeHint(\.confirm, "Run"), LoungeHint(\.back, "Cancel")]
        case .starting:
            return [LoungeHint(\.back, "Back")]
        case .home:
            var hints: [LoungeHint] = []
            switch lounge.focusedTile {
            case let .entry(entry) where lounge.status(of: entry) == .starting:
                hints.append(LoungeHint(\.confirm, "Show progress"))
            case let .entry(entry) where lounge.isRunning(entry):
                if case .dockerCompose(_, _, true) = entry.launch {
                    hints += [LoungeHint(\.confirm, "Resume"), LoungeHint(\.secondary, "Close")]
                } else {
                    hints += [LoungeHint(\.confirm, "Resume"), LoungeHint(\.secondary, "Quit")]
                }
            case .entry: hints.append(LoungeHint(\.confirm, "Open · hold to remove"))
            case .suggestion, .add: hints.append(LoungeHint(\.confirm, "Add"))
            case .exit: hints.append(LoungeHint(\.confirm, "Exit Lounge"))
            case nil: break
            }
            hints.append(LoungeHint([\.previous, \.next], "Switch space"))
            return hints
        }
    }
}

/// The desktop picture of the main display, and whether it's dark enough to
/// need light text.
struct LoungeWallpaper {
    var image: NSImage?
    var isDark = false

    @MainActor
    static func current() -> LoungeWallpaper {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else { return LoungeWallpaper() }
        return LoungeWallpaper(image: image, isDark: averageLuminance(image) < 0.5)
    }

    private static func averageLuminance(_ image: NSImage) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return 1 }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = data.assumingMemoryBound(to: UInt8.self)
        return (0.299 * CGFloat(p[0]) + 0.587 * CGFloat(p[1]) + 0.114 * CGFloat(p[2])) / 255
    }
}

/// "Lounge" on the left; clock and controller on the right.
struct LoungeTopBar: View {
    let h: CGFloat
    let controllerName: String?

    var body: some View {
        HStack(spacing: h * 0.02) {
            Text("Lounge").font(.system(size: h * 0.024, weight: .medium))
            Spacer()
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: h * 0.022)).monospacedDigit()
            }
            if controllerName != nil {
                Image(systemName: "gamecontroller.fill").font(.system(size: h * 0.024))
            }
        }
        .foregroundStyle(.primary)
        .padding(.top, h * 0.035)
    }
}

struct LoungeHint: Identifiable {
    let glyphs: [KeyPath<LoungeGlyphs, String>]
    let label: String
    var id: String { label }
    init(_ glyph: KeyPath<LoungeGlyphs, String>, _ label: String) {
        self.init([glyph], label)
    }
    init(_ glyphs: [KeyPath<LoungeGlyphs, String>], _ label: String) {
        self.glyphs = glyphs
        self.label = label
    }
}

struct LoungeHintBar: View {
    let hints: [LoungeHint]
    let glyphs: LoungeGlyphs
    let h: CGFloat

    var body: some View {
        HStack(spacing: h * 0.055) {
            ForEach(hints) { hint in
                HStack(spacing: h * 0.014) {
                    ForEach(hint.glyphs, id: \.self) { glyph in
                        Image(systemName: glyphs[keyPath: glyph]).font(.system(size: h * 0.03))
                    }
                    Text(hint.label).font(.system(size: h * 0.019))
                }
            }
        }
        .foregroundStyle(.primary.opacity(0.85))
    }
}

/// A frosted, centred row of tiles — the mockup's dock.
struct LoungeDock: View {
    @ObservedObject var lounge: LoungeController
    let row: Int
    let tiles: [LoungeTile]
    let h: CGFloat

    var body: some View {
        let icon = h * 0.11
        HStack(alignment: .top, spacing: h * 0.05) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { column, tile in
                let focused = lounge.focusRow == row && lounge.focusColumn == column
                LoungeTileView(tile: tile, focused: focused, size: icon,
                               status: { if case let .entry(e) = tile { return lounge.status(of: e) }; return nil }())
                    .onTapGesture {
                        lounge.focusRow = row
                        lounge.focusColumn = column
                        lounge.activate(tile)
                    }
                    .onLongPressGesture(minimumDuration: LoungeGamepad.holdDuration) {
                        lounge.focusRow = row
                        lounge.focusColumn = column
                        lounge.handle(.hold)
                    }
            }
        }
        .padding(.horizontal, h * 0.05)
        .padding(.top, h * 0.038)
        // Room for the focused tile's label, which hangs below the icons.
        .padding(.bottom, h * 0.05)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: h * 0.034, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: h * 0.034, style: .continuous)
            .strokeBorder(.white.opacity(0.4), lineWidth: 1))
        .animation(.spring(duration: 0.25), value: lounge.focusColumn)
        .animation(.spring(duration: 0.25), value: lounge.focusRow)
    }
}

struct LoungeTileView: View {
    let tile: LoungeTile
    let focused: Bool
    let size: CGFloat
    /// nil for tiles that aren't library entries (Add, Exit, suggestions).
    let status: LoungeController.Status?

    var body: some View {
        icon
            .frame(width: size, height: size)
            .padding(size * 0.06)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.primary.opacity(focused ? 0.85 : 0), lineWidth: size * 0.025)
            )
            .overlay(alignment: .topTrailing) {
                if let status { LoungeStatusDot(status: status, size: size * 0.13) }
            }
            // The label sits under the focused tile only, outside the layout so
            // the dock's height doesn't change as focus moves.
            .overlay(alignment: .bottom) {
                Text(title)
                    .font(.system(size: size * 0.2))
                    .fixedSize()
                    .offset(y: size * 0.36)
                    .opacity(focused ? 1 : 0)
            }
    }

    private var title: String {
        switch tile {
        case let .entry(e): return e.title
        case .add: return "Add"
        case .exit: return "Exit Lounge"
        case let .suggestion(app): return "Add \(app.name)"
        }
    }

    @ViewBuilder private var icon: some View {
        switch tile {
        case let .entry(entry):
            if case .web = entry.launch {
                symbolTile("globe")
            } else if case .dockerCompose = entry.launch {
                symbolTile("shippingbox")
            } else if let image = LoungeApps.icon(for: entry) {
                Image(nsImage: image).resizable()
            } else {
                symbolTile("questionmark")
            }
        case .add: symbolTile("plus")
        case .exit: symbolTile("rectangle.portrait.and.arrow.right")
        case let .suggestion(app):
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable()
        }
    }

    /// Non-app tiles drawn as app-icon-shaped plates so the dock stays even.
    private func symbolTile(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(.white.opacity(0.55))
            .padding(size * 0.08)
            .overlay(Image(systemName: name).font(.system(size: size * 0.34, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.7)))
    }
}

/// Red when off, pulsing orange while starting, green when running.
struct LoungeStatusDot: View {
    let status: LoungeController.Status
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white, lineWidth: size * 0.16))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .opacity(status == .starting && pulse ? 0.35 : 1)
            .animation(status == .starting ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
            .onChange(of: status) { _, _ in pulse.toggle(); pulse = true }
    }

    private var color: Color {
        switch status {
        case .off: return Color(red: 0.92, green: 0.26, blue: 0.24)
        case .starting: return Color(red: 0.98, green: 0.60, blue: 0.10)
        case .running: return Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }
}

/// "Remove <title>?" over a blurred home screen.
struct LoungeRemovePrompt: View {
    let entry: LoungeEntry
    let h: CGFloat

    var body: some View {
        VStack(spacing: h * 0.02) {
            Text("Remove \(entry.title)?").font(.system(size: h * 0.045, weight: .semibold))
            Text("It comes off your Lounge. The app itself isn't deleted.")
                .font(.system(size: h * 0.022)).foregroundStyle(.secondary)
        }
        .padding(h * 0.05)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: h * 0.034, style: .continuous))
    }
}

/// First launch of a project: the exact command, before anything runs.
struct LoungeLaunchPrompt: View {
    let entry: LoungeEntry
    let h: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: h * 0.02) {
            Text("Run \(entry.title)?").font(.system(size: h * 0.045, weight: .semibold))
            Text("Lounge will run:").font(.system(size: h * 0.022)).foregroundStyle(.secondary)
            Text(LoungeLaunchApproval.command(for: entry) ?? "")
                .font(.system(size: h * 0.02, design: .monospaced))
                .textSelection(.enabled)
                .padding(h * 0.015)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: h * 0.01))
            Text("You'll only be asked again if the project's file changes.")
                .font(.system(size: h * 0.018)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: h * 1.1, alignment: .leading)
        .padding(h * 0.05)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: h * 0.034, style: .continuous))
    }
}

struct LoungeStartingCard: View {
    let entry: LoungeEntry
    let status: String
    let h: CGFloat

    var body: some View {
        VStack(spacing: h * 0.025) {
            ProgressView().controlSize(.large)
            Text(entry.title).font(.system(size: h * 0.045, weight: .semibold))
            Text(status).font(.system(size: h * 0.022)).foregroundStyle(.secondary)
        }
        .padding(h * 0.05)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: h * 0.034, style: .continuous))
    }
}

/// Controller-driven picker of installed apps, games first.
struct LoungeAddPicker: View {
    @ObservedObject var lounge: LoungeController

    var body: some View {
        let apps = lounge.pickerApps
        VStack(alignment: .leading, spacing: 24) {
            Text("Add to Lounge").font(.system(size: 44, weight: .semibold))
            Text("Websites can be added in Settings ▸ Lounge.").font(.system(size: 20)).opacity(0.7)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            HStack(spacing: 16) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable().frame(width: 44, height: 44)
                                Text(app.name).font(.system(size: 24))
                                if app.isGame {
                                    Text("Game").font(.system(size: 14, weight: .semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.12), in: Capsule())
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color.primary.opacity(index == lounge.pickerIndex ? 0.12 : 0),
                                        in: RoundedRectangle(cornerRadius: 14))
                            .id(index)
                            .onTapGesture {
                                lounge.pickerIndex = index
                                lounge.handle(.confirm)
                            }
                        }
                    }
                }
                .onChange(of: lounge.pickerIndex) { _, index in
                    withAnimation { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, 90)
        .padding(.top, 90)
        .padding(.bottom, 120)
        .frame(maxWidth: 900, alignment: .leading)
    }
}

struct LoungeWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    /// The page takes keyboard focus as soon as it's shown, so it responds
    /// straight away instead of after a click.
    func updateNSView(_ nsView: WKWebView, context: Context) {
        DispatchQueue.main.async {
            if nsView.window?.firstResponder !== nsView { nsView.window?.makeFirstResponder(nsView) }
        }
    }
}
