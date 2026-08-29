import SwiftUI
import SpacemanCore

/// Edits one zone: its pages, each page's sections, and each section's modules,
/// colours and edge shapes.
///
/// The nesting is the model's, shown literally rather than flattened. A user who
/// can see that a section sits inside a page inside a zone can predict what
/// scrolling will do; a flat list of modules with a "page" column cannot explain
/// itself.
struct ZoneEditor: View {
    let side: ZoneSide
    let pages: [BarPage]
    @ObservedObject var preferences: Preferences
    let update: ([BarPage]) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if pages.isEmpty {
                    Text("Empty — this zone shows nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, page in
                    pageEditor(page, at: pageIndex)
                    if pageIndex < pages.count - 1 { Divider() }
                }

                Button {
                    update(pages + [BarPage([])])
                } label: {
                    Label("Add Page", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(6)
        } label: {
            HStack {
                Text(side.title)
                if pages.count > 1 {
                    Text("\(pages.count) pages — scroll to switch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pageEditor(_ page: BarPage, at pageIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Page \(pageIndex + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var updated = pages
                    updated.remove(at: pageIndex)
                    update(updated)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this page")
            }

            ForEach(Array(page.sections.enumerated()), id: \.offset) { sectionIndex, section in
                SectionEditor(
                    section: section,
                    preferences: preferences,
                    onChange: { updated in
                        replaceSection(updated, page: pageIndex, section: sectionIndex)
                    },
                    onDelete: {
                        var sections = page.sections
                        sections.remove(at: sectionIndex)
                        replacePage(BarPage(sections: sections), at: pageIndex)
                    }
                )
            }

            Button {
                replacePage(BarPage(sections: page.sections + [BarSection(modules: [])]),
                            at: pageIndex)
            } label: {
                Label("Add Section", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func replacePage(_ page: BarPage, at index: Int) {
        var updated = pages
        updated[index] = page
        update(updated)
    }

    private func replaceSection(_ section: BarSection, page: Int, section index: Int) {
        var sections = pages[page].sections
        sections[index] = section
        replacePage(BarPage(sections: sections), at: page)
    }
}

/// One section: its modules, its fill and text colours, and the shape of each
/// edge.
private struct SectionEditor: View {
    let section: BarSection
    @ObservedObject var preferences: Preferences
    let onChange: (BarSection) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                moduleChips
                Spacer()
                addModuleMenu
                Button(action: onDelete) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this section")
            }

            HStack(spacing: 12) {
                ColorRefPicker(title: "Fill", value: section.fill,
                               preferences: preferences) { value in
                    var updated = section
                    updated.fill = value
                    onChange(updated)
                }
                ColorRefPicker(title: "Text", value: section.text,
                               preferences: preferences) { value in
                    var updated = section
                    updated.text = value
                    onChange(updated)
                }
            }

            HStack(spacing: 12) {
                edgeEditor("Leading", shape: section.leadingEdge) { shape in
                    var updated = section
                    updated.leadingEdge = shape
                    onChange(updated)
                }
                edgeEditor("Trailing", shape: section.trailingEdge) { shape in
                    var updated = section
                    updated.trailingEdge = shape
                    onChange(updated)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var moduleChips: some View {
        HStack(spacing: 4) {
            if section.modules.isEmpty {
                Text("No modules").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(section.modules.enumerated()), id: \.offset) { index, module in
                HStack(spacing: 3) {
                    Text(BarModuleCatalog.title(for: module)).font(.caption)
                    Button {
                        var updated = section
                        updated.modules.remove(at: index)
                        onChange(updated)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 7))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }
        }
    }

    private var addModuleMenu: some View {
        Menu {
            ForEach(BarModuleCatalog.available) { descriptor in
                Button {
                    var updated = section
                    updated.modules.append(descriptor.module)
                    onChange(updated)
                } label: {
                    // Title and summary, so the picker says what each module
                    // shows rather than leaving you to add one and find out.
                    Text(descriptor.title)
                    Text(descriptor.summary)
                }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a module to this section")
    }

    private func edgeEditor(_ title: String, shape: EdgeShape,
                            onEdit: @escaping (EdgeShape) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { shape.style },
                // A style change keeps the width, so flipping between Down Slash
                // and Gap to compare them doesn't lose the size already dialled
                // in. Vertical simply ignores it.
                set: { onEdit(EdgeShape(style: $0, width: widthOrDefault(shape))) }
            )) {
                ForEach(EdgeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Stepper(value: Binding(
                get: { shape.width },
                set: { onEdit(EdgeShape(style: shape.style, width: $0, fill: shape.fill)) }
            ), in: 0...48, step: 2) {
                Text("\(Int(shape.width))pt").font(.caption).monospacedDigit()
            }
            .fixedSize()
            .disabled(!shape.style.usesWidth)
            .opacity(shape.style.usesWidth ? 1 : 0.4)

            // Only a gap has a region of its own to colour; a slash is a line
            // its two neighbours share.
            if shape.style == .gap {
                ColorRefPicker(title: "", value: shape.fill, preferences: preferences) { fill in
                    onEdit(EdgeShape(style: shape.style, width: shape.width, fill: fill))
                }
                .help("Leave as None for an empty gap, or colour it to make a divider")
            }
        }
    }

    /// Switching away from Vertical with a width of zero would appear to do
    /// nothing, so give it something visible to start from.
    private func widthOrDefault(_ shape: EdgeShape) -> Double {
        shape.width > 0 ? shape.width : 12
    }
}

/// Picks a theme role, a literal colour, or nothing.
///
/// Roles are listed first and are the intended choice: a section filled with
/// `accent` keeps following the user's system accent and their dark mode, where
/// a literal is frozen at whatever it was picked as.
private struct ColorRefPicker: View {
    let title: String
    let value: ColorRef?
    @ObservedObject var preferences: Preferences
    let onChange: (ColorRef?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)

            Menu {
                Button("None") { onChange(nil) }
                Divider()
                ForEach(ThemeRole.allCases, id: \.self) { role in
                    Button(role.title) { onChange(.role(role)) }
                }
            } label: {
                HStack(spacing: 4) {
                    swatch
                    Text(label).font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Only offered once the section has a colour, so the common
            // role-based path isn't cluttered by a picker nobody wanted.
            if value != nil {
                ColorPicker("", selection: Binding(
                    get: { swatchColor ?? .clear },
                    set: { onChange(.hex($0.hexColor)) }
                ), supportsOpacity: true)
                .labelsHidden()
                .help("Pick a literal colour instead of a theme role")
            }
        }
    }

    private var label: String {
        switch value {
        case .none:            return "None"
        case .role(let role):  return role.title
        case .hex(let hex):    return hex.hexString
        }
    }

    private var swatchColor: Color? {
        value.map { Theme.color($0, from: preferences) }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(swatchColor ?? .clear)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.quaternary))
            .frame(width: 12, height: 12)
    }
}
