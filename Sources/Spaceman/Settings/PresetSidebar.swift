import SwiftUI
import SpacemanCore

/// The preset list shared by the Bars and Palette panes.
///
/// Selecting a preset activates it. There is no separate "apply" step and no
/// checkmark, because with one click doing both there is nothing for a checkmark
/// to disambiguate — the highlighted row *is* the active preset.
///
/// Selection is left entirely to `List`. An earlier version added a tap gesture
/// to the rows, which swallowed the click `List` needed and left the highlight
/// stuck on whatever was selected first.
struct PresetSidebar<P: Preset>: View {
    let store: PresetStore<P>
    @Binding var selection: String?
    /// Shown under the list, e.g. "Duplicate to customise".
    let footnote: String

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Built-in") {
                    ForEach(P.builtIns) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                if !store.custom.isEmpty {
                    Section("Custom") {
                        ForEach(store.custom) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 2) {
                Button {
                    let copy = store.editableCopy(of: selected)
                    store.save(copy)
                    selection = copy.name
                } label: {
                    Image(systemName: "plus")
                }
                .help("Duplicate '\(selected.name)'")

                Button {
                    let name = selected.name
                    selection = P.defaultName
                    store.delete(name)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected.isBuiltIn)
                .help(selected.isBuiltIn ? "Built-in presets cannot be deleted"
                                         : "Delete '\(selected.name)'")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selected: P {
        store.all.first { $0.name == selection } ?? store.active
    }
}

/// The editable title of a custom preset, or a plain label plus a "Built-in"
/// badge for one that ships with the app.
///
/// Renaming happens here rather than in the list: an inline list rename competes
/// with the single click that activates a preset, and there is no gesture left
/// that means "rename" without also meaning "switch to this".
struct PresetTitle<P: Preset>: View {
    let preset: P
    let store: PresetStore<P>
    @Binding var selection: String?

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if preset.isBuiltIn {
                Text(preset.name).font(.headline)
                Text("Built-in")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            } else {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($focused)
                    .frame(maxWidth: 240)
                    .onSubmit(commit)
                    // Committing on focus loss as well as on Return: a user who
                    // types a name and clicks straight into the editor below
                    // means the rename, and losing it would be surprising.
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            }
        }
        .onAppear { draft = preset.name }
        .onChange(of: preset.name) { _, name in draft = name }
    }

    /// A blank or already-taken name is refused and the field snaps back, so the
    /// list can never show two presets with one name.
    private func commit() {
        guard draft != preset.name else { return }
        if store.rename(preset, to: draft) {
            selection = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            draft = preset.name
        }
    }
}
