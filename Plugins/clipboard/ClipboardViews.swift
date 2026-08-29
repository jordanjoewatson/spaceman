import SwiftUI
import PluginKit

/// A horizontally scrolling row of pills, one per saved snippet.
///
/// Width is capped so a full history cannot shove neighbouring bar zones off
/// the screen; overflow scrolls inside the row.
struct ClipboardBarModule: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var palette: PluginPalette
    let onCopied: () -> Void

    private let maxRowWidth: CGFloat = 420

    var body: some View {
        if store.items.isEmpty {
            Text("clipboard empty")
                .foregroundStyle(palette.color(.muted))
        } else {
            ChipRow(items: store.items, maxWidth: maxRowWidth) { item in
                ClipboardChip(item: item, palette: palette,
                              onPin: { store.togglePin(item.text) },
                              onCopy: {
                                  ClipboardCapture.writeToPasteboard(item.text)
                                  onCopied()
                              })
            }
        }
    }
}

/// Natural width up to `maxWidth`, then a horizontal scroll.
///
/// The bar measures modules at their ideal size. A ScrollView's ideal size is
/// its content, so without an explicit cap a long history would widen the
/// zone without bound.
private struct ChipRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let maxWidth: CGFloat
    @ViewBuilder let content: (Item) -> Content

    @State private var contentWidth: CGFloat

    init(items: [Item], maxWidth: CGFloat, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.maxWidth = maxWidth
        self.content = content
        _contentWidth = State(initialValue: maxWidth)
    }

    var body: some View {
        let width = min(max(contentWidth, 1), maxWidth)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    content(item)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ChipRowWidthKey.self, value: proxy.size.width)
            })
        }
        .frame(width: width)
        .onPreferenceChange(ChipRowWidthKey.self) { measured in
            if measured > 0 { contentWidth = measured }
        }
    }
}

private struct ChipRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ClipboardChip: View {
    let item: ClipboardItem
    @ObservedObject var palette: PluginPalette
    let onPin: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onPin) {
                Image(systemName: item.pinned ? "star.fill" : "star")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(item.pinned
                                     ? palette.color(.accent)
                                     : palette.color(.muted))
            }
            .buttonStyle(.plain)
            .help(item.pinned ? "Unpin" : "Pin — kept when the history fills")

            Button(action: onCopy) {
                Text(ClipboardHistory.preview(item.text))
                    .lineLimit(1)
                    .foregroundStyle(palette.color(.text))
            }
            .buttonStyle(.plain)
            .help(tooltip)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(palette.color(item.pinned ? .accent : .surface).opacity(item.pinned ? 0.35 : 1),
                    in: Capsule())
    }

    private var tooltip: String {
        if item.text.count <= 200 { return item.text }
        return String(item.text.prefix(199)) + "…"
    }
}

struct ClipboardSettingsPane: View {
    @ObservedObject var store: ClipboardStore

    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(
                    get: { store.capacity },
                    set: { store.capacity = $0 }
                ), in: ClipboardHistory.minCapacity...ClipboardHistory.maxCapacity) {
                    Text("Keep \(store.capacity) snippets")
                }
            } footer: {
                Text("⌃⌥C copies the current selection and saves it here. "
                     + "⌘C is unchanged and never recorded. "
                     + "Star a snippet to keep it when newer ones arrive.")
            }
        }
        .formStyle(.grouped)
    }
}
