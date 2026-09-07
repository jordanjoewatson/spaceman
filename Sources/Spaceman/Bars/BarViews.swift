import AppKit
import SwiftUI
import SpacemanCore

/// A bar, rendered from its `BarLayout`.
///
/// Replaces the previous hand-written `TopBar`/`BottomBar`: both bars are now
/// the same view driven by different data, which is what makes them
/// configurable at all. The Settings preview renders this too, so what the
/// editor shows is the bar, not an approximation of it.
struct BarView: View {
    let edge: BarEdge
    let barHeight: CGFloat
    let context: BarContext
    let router: ZoneScrollRouter
    /// Observed so module, colour and slant edits repaint a live bar. Only
    /// height and floating need `BarController` to rebuild the window, because
    /// only those are fixed when an `NSPanel` is created.
    @ObservedObject var preferences: Preferences
    /// The same object `context` carries, declared again so SwiftUI *observes*
    /// it. Reaching `BarState` only through the plain `BarContext` struct meant
    /// nothing subscribed to it, and every module froze at whatever it showed
    /// when the bar was built — a layout name that never changed, a clock that
    /// never ticked. One observer at the root repaints the whole bar.
    @ObservedObject var state: BarState

    private var layout: BarLayout {
        let preset = preferences.activeBarPreset
        return edge == .top ? preset.top : preset.bottom
    }

    /// Uncoloured gaps, reported upward by the zones. Held here because only the
    /// bar knows where its background is.
    @State private var holes: [CGRect] = []

    var body: some View {
        ZStack {
            // Unpadded, so the material spans the whole bar. Padding the
            // background along with the content inset the frosted surface
            // itself and left bare strips at both ends of the bar.
            BarBackground(layout: layout,
                          preferences: context.preferences,
                          holes: holes)

            standardModules
        }
        .frame(height: barHeight)
        .coordinateSpace(name: BarCoordinateSpace.name)
        .onPreferenceChange(BarHolesKey.self) { holes = $0 }
    }

    private var standardModules: some View {
        // Leading and trailing are pinned to their edges; center is centered
        // on the bar rather than between them, so the clock doesn't drift as
        // the front app's name changes length.
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

    private func zone(_ side: ZoneSide) -> some View {
        BarZoneView(side: side,
                    pages: layout.pages(side),
                    height: barHeight,
                    context: context,
                    // Cancels the bar's side padding so an edge zone's fill can
                    // run flush to the bar boundary instead of stopping short.
                    bleed: side == .center ? 0 : layout.edgePadding,
                    router: router)
    }
}

/// Frosted background so bars read as system chrome rather than windows.
///
/// The material carries the appearance; `barSurface` is a tint over it. That
/// split is why bars keep working under Reduce Transparency and desktop
/// tinting — the material handles both, and the tint is only ever a wash.
struct BarBackground: View {
    let layout: BarLayout
    @ObservedObject var preferences: Preferences
    /// Regions to cut out entirely, in bar coordinates.
    var holes: [CGRect] = []

    var body: some View {
        VisualEffect(material: material)
            .overlay(Theme.color(.barSurface, from: preferences))
            // Both the material and its tint are masked, so an uncoloured gap
            // is a hole right through the bar rather than a space with the bar
            // still visible behind it.
            .mask {
                PunchedBar(holes: holes, cornerRadius: layout.cornerRadius)
                    .fill(style: FillStyle(eoFill: true))
            }
            .overlay {
                // A flush bar gets a hairline; with no gap and no shadow it is
                // the only thing separating the bar from the window behind it.
                if !layout.floating {
                    Rectangle()
                        .fill(Theme.color(.separator, from: preferences))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .shadow(color: layout.floating ? .black.opacity(0.25) : .clear,
                    radius: layout.floating ? 6 : 0, y: 1)
    }

    private var material: NSVisualEffectView.Material {
        BarMaterial(rawValue: layout.material)?.material ?? .hudWindow
    }
}

/// The bar's shape with its uncoloured gaps removed.
///
/// Filled with the even-odd rule, so each hole subtracts from the bar rather
/// than adding to it — one path rather than a stack of masks, which keeps the
/// rounded ends intact however many holes there are.
private struct PunchedBar: Shape {
    let holes: [CGRect]
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        for hole in holes where !hole.isEmpty {
            path.addRect(hole)
        }
        return path
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
