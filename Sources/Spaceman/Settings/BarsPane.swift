import AppKit
import SwiftUI
import SpacemanCore

/// The bar editor: a preset list beside an editor for the selected preset.
///
/// Terminal.app's Profiles pane, which is the macOS convention for this shape of
/// setting. Built-ins are genuinely read-only — their controls are disabled
/// rather than silently forking on edit — so the way to customise one is to
/// duplicate it, which is visible and undoable.
struct BarsPane: View {
    @ObservedObject var preferences: Preferences
    @State private var selection: String?
    @State private var editingEdge: BarEdge = .top
    @State private var displays: [NSScreen] = Self.currentScreens()

    private var store: PresetStore<BarPreset> { preferences.barPresets }

    private var selected: BarPreset {
        store.all.first { $0.name == selection } ?? store.active
    }

    var body: some View {
        HStack(spacing: 0) {
            PresetSidebar(store: store,
                          selection: $selection,
                          footnote: "Selecting a preset applies it. Use + to make an editable copy.")
                .frame(width: 200)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = store.activeName }
        .onAppear { displays = Self.currentScreens() }
        .onChange(of: selection) { _, name in
            // Selecting is applying — see PresetSidebar.
            if let name, name != store.activeName { store.activeName = name }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            displays = Self.currentScreens()
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

            BarPreview(layout: layout(for: editingEdge),
                       palette: preferences.activePalette,
                       preferences: preferences)

            Picker("", selection: $editingEdge) {
                Text("Top Bar").tag(BarEdge.top)
                Text("Bottom Bar").tag(BarEdge.bottom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            edgeRevealToggle

            offsetsSection

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    appearanceSection
                    ForEach(ZoneSide.allCases, id: \.self) { side in
                        ZoneEditor(side: side,
                                   pages: layout(for: editingEdge).pages(side),
                                   preferences: preferences,
                                   update: { pages in
                                       edit { $0.setPages(pages, for: side) }
                                   })
                    }
                }
            }
            // Built-ins are read-only: the whole editor greys out rather than
            // accepting a change and quietly redirecting it somewhere else.
            .disabled(selected.isBuiltIn)
            .opacity(selected.isBuiltIn ? 0.55 : 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var appearanceSection: some View {
        GroupBox("Bar") {
            let current = layout(for: editingEdge)
            VStack(alignment: .leading, spacing: 8) {
                slider("Height", value: current.height, range: 18...48) { value in
                    edit { $0.height = value }
                }

                slider("Side padding", value: current.edgePadding, range: 0...40) { value in
                    edit { $0.edgePadding = value }
                }
                .help("Gap between the bar's content and its left and right ends")

                Picker("Material", selection: Binding(
                    get: { BarMaterial(rawValue: current.material) ?? .hudWindow },
                    set: { value in edit { $0.material = value.rawValue } }
                )) {
                    ForEach(BarMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                }

                Toggle("Floating", isOn: Binding(
                    get: { current.floating },
                    set: { value in edit { $0.floating = value } }
                ))
                .help("Inset from the screen edges with a shadow, instead of flush")

                slider("Corner radius", value: current.cornerRadius, range: 0...16) { value in
                    edit { $0.cornerRadius = value }
                }
            }
            .padding(6)
        }
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>,
                        onChange: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(get: { value }, set: onChange), in: range, step: 1)
            Text("\(Int(value))pt")
                .font(.caption).monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func layout(for edge: BarEdge) -> BarLayout {
        edge == .top ? selected.top : selected.bottom
    }

    private var edgeRevealToggle: some View {
        Toggle("Hide bars at screen edges", isOn: Binding(
            get: { preferences[Defaults.barEdgeReveal] },
            set: { preferences[Defaults.barEdgeReveal] = $0 }
        ))
        .help("Slide a bar out of the way when the pointer reaches the top or bottom of that display")
    }

    private var offsetsSection: some View {
        GroupBox("Display offsets") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Positive values move a bar up. Negative values move it down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(displays, id: \.displayID) { screen in
                    let offsets = preferences.barOffsets(for: screen.displayID)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(screen.localizedName)
                            Spacer()
                            Button("Reset") {
                                preferences.setBarOffset(0, for: screen.displayID, edge: .top)
                                preferences.setBarOffset(0, for: screen.displayID, edge: .bottom)
                            }
                            .disabled(offsets == DisplayBarOffsets())
                        }

                        slider("Top", value: offsets.top, range: -200...200) { value in
                            preferences.setBarOffset(value, for: screen.displayID, edge: .top)
                        }
                        slider("Bottom", value: offsets.bottom, range: -200...200) { value in
                            preferences.setBarOffset(value, for: screen.displayID, edge: .bottom)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(6)
        }
    }

    /// Apply a change to the bar being edited. Built-ins never reach here — the
    /// editor is disabled for them — so this only ever writes a custom preset.
    private func edit(_ change: (inout BarLayout) -> Void) {
        var preset = selected
        guard !preset.isBuiltIn else { return }
        switch editingEdge {
        case .top:    change(&preset.top)
        case .bottom: change(&preset.bottom)
        }
        store.save(preset)
        selection = preset.name
    }

    private static func currentScreens() -> [NSScreen] {
        NSScreen.screens.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.frame.minY < $1.frame.minY
        }
    }
}

// MARK: - Live preview

/// The real `BarView` body, rendered against sample state at the pane's width.
///
/// Not a mock-up: an approximation would drift from the bars every time either
/// changed, and "what will this look like" is the only question this pane exists
/// to answer.
struct BarPreview: View {
    let layout: BarLayout
    let palette: PalettePreset
    @ObservedObject var preferences: Preferences
    @StateObject private var sampleState = BarState.sample()
    @StateObject private var router = ZoneScrollRouter()

    @State private var holes: [CGRect] = []

    var body: some View {
        ZStack {
            // Same arrangement as a live bar: surface unpadded so it spans the
            // full width, content inset within it, and uncoloured gaps cut out
            // so a hole reads as a hole here too.
            Theme.color(.surface, in: palette)
                .mask {
                    PreviewPunchedBar(holes: holes, cornerRadius: layout.cornerRadius)
                        .fill(style: FillStyle(eoFill: true))
                }

            ZStack {
                HStack(spacing: 8) {
                    zone(.leading)
                    Spacer(minLength: 8)
                    zone(.trailing)
                }
                zone(.center)
            }
            .padding(.horizontal, layout.edgePadding)
        }
        .frame(height: layout.height)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: max(layout.cornerRadius, 6))
            .strokeBorder(.quaternary))
        .coordinateSpace(name: BarCoordinateSpace.name)
        .onPreferenceChange(BarHolesKey.self) { holes = $0 }
    }

    private func zone(_ side: ZoneSide) -> some View {
        BarZoneView(side: side,
                    pages: layout.pages(side),
                    height: layout.height,
                    context: .preview(state: sampleState,
                                      preferences: preferences,
                                      palette: palette),
                    bleed: side == .center ? 0 : layout.edgePadding,
                    router: router)
    }
}

/// The preview surface with its uncoloured gaps removed, mirroring `PunchedBar`
/// in the live bar.
private struct PreviewPunchedBar: Shape {
    let holes: [CGRect]
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        for hole in holes where !hole.isEmpty { path.addRect(hole) }
        return path
    }
}

extension BarState {
    /// Plausible values so every module has something to draw in the preview.
    /// An empty preview would make a correct layout look broken.
    static func sample() -> BarState {
        let state = BarState()
        state.spaceDots[0] = [
            SpaceDot(isCurrent: false),
            SpaceDot(isCurrent: true),
            SpaceDot(isCurrent: false),
            SpaceDot(isCurrent: false),
        ]
        state.layoutModes[0] = .spaceman
        state.clock = "14:32:07"
        state.date = "Mon 9 Jun"
        state.moverName = "AX"
        state.moverReady = true
        state.status = "Sample status"
        state.battery = BatteryReading(percent: 82, isCharging: false, isPresent: true)
        return state
    }
}
