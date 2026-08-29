import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PluginKit
import SpacemanCore

/// Assigns the key each command hangs off the leader.
///
/// The leader itself stays a compile-time constant — every chord is
/// leader+something, so there is nothing to record and no modifier picker. What
/// varies is the key, which is why this is a table of one-character fields
/// rather than a shortcut recorder.
///
/// Overrides live in `UserDefaults` under `shortcut.<command id>`, so a plugin's
/// binding survives that plugin being recompiled and is scriptable like every
/// other preference.
struct ShortcutsPane: View {
    @ObservedObject var preferences: Preferences
    let commands: [PluginCommand]

    private var bindings: ShortcutBindings { preferences.shortcuts }

    /// Grouped in the enum's declaration order, matching the ⌃⌥H sheet.
    /// Open-app chords have their own section below, so they are left out here.
    // Qualified: SwiftUI has a `CommandGroup` of its own.
    private var groups: [(group: PluginKit.CommandGroup, commands: [PluginCommand])] {
        PluginKit.CommandGroup.allCases.compactMap { group in
            let matching = commands.filter {
                $0.group == group && !$0.desc.isEmpty && !$0.id.hasPrefix("apps.")
            }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.group) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.group.title).font(.headline)
                            ForEach(entry.commands, id: \.id) { command in
                                ShortcutRow(command: command, bindings: bindings)
                            }
                        }
                    }

                    OpenAppsSection(preferences: preferences, bindings: bindings)
                }
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Text("Changes take effect at the next launch — chords are "
                     + "registered with the system once, at startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset All") { bindings.resetAll(commands.map(\.id)) }
                    .disabled(!bindings.hasOverrides(commands.map(\.id)))
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Leader is \(ChordGlyphs.leaderGlyphs) — every command is the leader "
                 + "plus the key below.")
                .font(.callout)
            Text("Duplicate keys are refused: the second one would silently never fire.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}

private struct ShortcutRow: View {
    let command: PluginCommand
    let bindings: ShortcutBindings

    @State private var text = ""
    @State private var rejected = false

    private var isOverridden: Bool { bindings.override(for: command.id) != nil }

    var body: some View {
        HStack(spacing: 10) {
            Text(command.desc)
                .frame(width: 260, alignment: .leading)

            Text(ChordGlyphs.leaderGlyphs)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("", text: $text)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            if rejected {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Already used by another command, or not a bindable key")
            }

            Spacer()

            Button {
                bindings.clear(command.id)
                text = currentText
                rejected = false
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!isOverridden)
            .help("Back to the built-in key")
        }
        .onAppear { text = currentText }
    }

    private var currentText: String {
        ChordGlyphs.keyName(bindings.keyCode(for: command))
    }

    /// A rejected key leaves the field as it was rather than accepting something
    /// that would never fire.
    private func commit() {
        rejected = !bindings.assign(text, to: command.id)
        text = currentText
    }
}

/// User-defined app chords. The key lives on the shortcut itself rather than
/// as a `shortcut.<id>` override — there is no built-in default to reset to.
private struct OpenAppsSection: View {
    @ObservedObject var preferences: Preferences
    let bindings: ShortcutBindings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App shortcuts").font(.headline)
            Text("Open launches or activates an app; its windows tile as usual. "
                 + "Popup opens it floating and never tiled — the same key "
                 + "minimizes it, and brings it back if it is already minimized. "
                 + "Chords register at the next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(preferences.appShortcuts) { shortcut in
                AppShortcutRow(shortcut: shortcut,
                               preferences: preferences,
                               bindings: bindings)
            }

            HStack(spacing: 12) {
                Button("Add App…") { addApp(kind: .open) }
                Button("Add Popup…") { addApp(kind: .popup) }
            }
            .padding(.top, 2)
        }
        .padding(.top, 8)
    }

    private func addApp(kind: AppShortcutKind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = kind == .popup
            ? "Choose an application to toggle as a floating popup"
            : "Choose an application to open with the leader key"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var shortcuts = preferences.appShortcuts
        if shortcuts.contains(where: { sameApp($0, as: url, kind: kind) }) { return }
        guard let key = AppShortcut.firstFreeKey(taken: bindings.takenKeyCodes) else { return }
        shortcuts.append(AppLauncher.makeShortcut(from: url, keyCode: key, kind: kind))
        preferences.appShortcuts = shortcuts
    }

    private func sameApp(_ shortcut: AppShortcut, as url: URL, kind: AppShortcutKind) -> Bool {
        guard shortcut.kind == kind else { return false }
        if shortcut.path == url.path { return true }
        if let bundleID = Bundle(url: url)?.bundleIdentifier,
           shortcut.bundleIdentifier == bundleID { return true }
        return false
    }
}

private struct AppShortcutRow: View {
    let shortcut: AppShortcut
    @ObservedObject var preferences: Preferences
    let bindings: ShortcutBindings

    @State private var text = ""
    @State private var rejected = false

    private var kindBinding: Binding<AppShortcutKind> {
        Binding(
            get: { shortcut.kind },
            set: { newKind in
                var shortcuts = preferences.appShortcuts
                guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
                shortcuts[index].kind = newKind
                preferences.appShortcuts = shortcuts
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: shortcut.path))
                .resizable()
                .frame(width: 16, height: 16)

            Text(shortcut.name)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)

            Picker("", selection: kindBinding) {
                ForEach(AppShortcutKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 88)
            .pickerStyle(.menu)
            .help("Open tiles as usual. Popup floats and never tiles.")

            Text(ChordGlyphs.leaderGlyphs)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            TextField("", text: $text)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            if rejected {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Already used by another command, or not a bindable key")
            }

            Spacer()

            Button {
                preferences.appShortcuts.removeAll { $0.id == shortcut.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this app shortcut")
        }
        .onAppear { text = ChordGlyphs.keyName(shortcut.keyCode) }
        .onChange(of: shortcut.keyCode) { _, code in
            text = ChordGlyphs.keyName(code)
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.count == 1, let code = ChordGlyphs.keyCode(for: trimmed) else {
            rejected = true
            text = ChordGlyphs.keyName(shortcut.keyCode)
            return
        }
        guard !bindings.isTaken(code, excluding: shortcut.commandID) else {
            rejected = true
            text = ChordGlyphs.keyName(shortcut.keyCode)
            return
        }
        rejected = false
        var shortcuts = preferences.appShortcuts
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        shortcuts[index].keyCode = code
        preferences.appShortcuts = shortcuts
        text = ChordGlyphs.keyName(code)
    }
}
