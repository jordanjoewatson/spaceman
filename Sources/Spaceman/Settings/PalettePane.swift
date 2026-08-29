import AppKit
import SwiftUI
import SpacemanCore

/// The colour editor, built exactly like the bar editor: a preset list beside an
/// editor for the selected palette.
///
/// Bars name their colours by role, so switching palette re-colours every preset
/// at once — including the built-in bar presets, which is what lets them be
/// read-only and still look like yours.
struct PalettePane: View {
    @ObservedObject var preferences: Preferences
    @State private var selection: String?

    private var store: PresetStore<PalettePreset> { preferences.palettes }

    private var selected: PalettePreset {
        store.all.first { $0.name == selection } ?? store.active
    }

    var body: some View {
        HStack(spacing: 0) {
            PresetSidebar(store: store,
                          selection: $selection,
                          footnote: "Selecting a palette applies it. Use + to make an editable copy.")
                .frame(width: 200)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = store.activeName }
        .onChange(of: selection) { _, name in
            if let name, name != store.activeName { store.activeName = name }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PresetTitle(preset: selected, store: store, selection: $selection)
                Spacer()
                if selected.isBuiltIn {
                    Button("Duplicate to Customise") {
                        let copy = store.editableCopy(of: selected)
                        store.save(copy)
                        selection = copy.name
                    }
                }
            }

            BarPreview(layout: preferences.activeBarPreset.top,
                       palette: selected,
                       preferences: preferences)

            HStack {
                Text("Light").frame(width: 54)
                Text("Dark").frame(width: 54)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(ThemeRole.allCases, id: \.self) { role in
                        PaletteRow(role: role,
                                   palette: selected,
                                   onChange: { updated in store.save(updated) })
                    }
                }
            }
            .disabled(selected.isBuiltIn)
            .opacity(selected.isBuiltIn ? 0.55 : 1)

            Text(selected.isBuiltIn
                 ? "Built-in palettes are read-only. Duplicate this one to change its colours."
                 : "A role left unset follows macOS — its accent, dark mode and contrast settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PaletteRow: View {
    let role: ThemeRole
    let palette: PalettePreset
    let onChange: (PalettePreset) -> Void

    private var isSet: Bool { palette.color(for: role) != nil }

    var body: some View {
        HStack(spacing: 8) {
            well(dark: false)
            well(dark: true)
            Text(role.title)
            Spacer()
            Button {
                var updated = palette
                updated.clear(role)
                onChange(updated)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!isSet)
            .help("Follow the system colour for \(role.title)")
        }
    }

    /// The well always shows the colour actually in use, so an unset role
    /// displays its system colour rather than an empty swatch — you can see the
    /// palette before you start changing it. Editing one writes that appearance
    /// only, leaving the other still following the system.
    private func well(dark: Bool) -> some View {
        ColorPicker("", selection: Binding(
            get: { Color(nsColor: NSColor(Theme.resolved(role, dark: dark, in: palette))) },
            set: { color in
                var updated = palette
                updated.setColor(color.hexColor, for: role, dark: dark)
                onChange(updated)
            }
        ), supportsOpacity: true)
        .labelsHidden()
        .frame(width: 54, alignment: .leading)
    }
}
