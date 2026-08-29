import AppKit
import SwiftUI
import SpacemanCore

/// Delivers scroll events to whichever zone the pointer is over.
///
/// Scroll cannot be caught by a SwiftUI overlay: an overlay that hit-tests
/// receives the scroll but swallows clicks meant for the buttons underneath, and
/// one that doesn't hit-test receives nothing. So `BarWindow` takes the event
/// from the responder chain — where it arrives because nothing in a bar consumes
/// scroll — and asks this router which zone it belongs to.
///
/// Only x matters: a bar is one row tall, so the zone under the pointer is fully
/// determined by horizontal position.
@MainActor
final class ZoneScrollRouter: ObservableObject {

    private struct Target {
        var range: ClosedRange<CGFloat>
        var handler: (CGFloat) -> Void
    }

    private var targets: [ZoneSide: Target] = [:]

    /// Zones with a single page never register, so a scroll over them falls
    /// through to no-one rather than paging something else.
    func register(_ side: ZoneSide, minX: CGFloat, maxX: CGFloat,
                  handler: @escaping (CGFloat) -> Void) {
        guard maxX > minX else { return }
        targets[side] = Target(range: minX...maxX, handler: handler)
    }

    func unregister(_ side: ZoneSide) {
        targets[side] = nil
    }

    func scroll(delta: CGFloat, atX x: CGFloat) {
        for target in targets.values where target.range.contains(x) {
            target.handler(delta)
            return
        }
    }
}

/// One zone of a bar: the current page's sections, painted and laid out.
///
/// Section widths have to be known before the fills can be shaped, because a
/// boundary's position depends on how wide its neighbour's content turned out.
/// SwiftUI cannot answer "how wide would this be" inline, so the content is
/// measured in a hidden pass and the real layout runs against those widths. The
/// extra pass re-runs only when a module's size actually changes.
struct BarZoneView: View {
    let side: ZoneSide
    let pages: [BarPage]
    let height: CGFloat
    let context: BarContext
    /// How far the outer fill may extend past this zone to reach the bar edge.
    let bleed: CGFloat
    let router: ZoneScrollRouter

    @State private var widths: [Int: CGFloat] = [:]
    @State private var page = 0
    @State private var scrollAccumulator: CGFloat = 0

    private var sections: [BarSection] {
        guard !pages.isEmpty else { return [] }
        return pages[min(page, pages.count - 1)].sections
    }

    var body: some View {
        let measured = (0..<sections.count).map { widths[$0] ?? 0 }
        let layout = BarGeometry.layout(sections: sections,
                                        contentWidths: measured,
                                        height: height,
                                        side: side,
                                        bleed: bleed)

        HStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.sections.enumerated()), id: \.offset) { index, frame in
                    if !frame.quad.isEmpty, let fill = sections[index].fill {
                        SectionShape(points: frame.quad)
                            .fill(Theme.color(fill, in: context.palette))
                    }
                }

                // A coloured gap paints as a divider. An uncoloured one paints
                // nothing here — it is cut out of the bar's material instead,
                // via the hole rects published below.
                ForEach(Array(layout.gaps.enumerated()), id: \.offset) { _, gap in
                    if let fill = gap.fill {
                        SectionShape(points: gap.quad)
                            .fill(Theme.color(fill, in: context.palette))
                    }
                }

                ForEach(Array(layout.sections.enumerated()), id: \.offset) { index, frame in
                    SectionContent(section: sections[index], context: context)
                        // Natural width, matching what the measurement pass
                        // reported. Without this the ZStack proposes its own
                        // width to each child and the last module truncates —
                        // a battery reading "100%" rendering as "10…".
                        .fixedSize()
                        .frame(height: height)
                        .offset(x: frame.contentX)
                }
            }
            .frame(width: layout.width, height: height, alignment: .topLeading)
            .background(measurementLayer)
            .background(holeReporter(layout.gaps))

            if pages.count > 1 {
                PageDots(count: pages.count, current: page, context: context) {
                    page = (page + 1) % pages.count
                }
                .frame(height: height)
            }
        }
        .background(scrollRegistration)
    }

    /// The hidden pass. Renders each section's content at its natural size and
    /// reports the width, contributing nothing visible.
    private var measurementLayer: some View {
        HStack(spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                SectionContent(section: section, context: context)
                    .fixedSize()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SectionWidthKey.self,
                                               value: [index: proxy.size.width])
                    })
            }
        }
        .hidden()
        .onPreferenceChange(SectionWidthKey.self) { widths = $0 }
    }

    /// Publishes uncoloured gaps in the bar's coordinate space, so the bar
    /// background can cut them out of its material.
    ///
    /// The zone computes its geometry locally and only the bar knows where the
    /// zone ended up, so the translation has to happen here and travel upward as
    /// a preference.
    private func holeReporter(_ gaps: [BarGeometry.GapFrame]) -> some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .named(BarCoordinateSpace.name)).origin
            Color.clear.preference(
                key: BarHolesKey.self,
                value: gaps.filter { $0.fill == nil }.map { gap in
                    gap.rect.offsetBy(dx: origin.x, dy: origin.y)
                }
            )
        }
    }

    /// Publishes this zone's horizontal extent so the router can find it, and
    /// cycles pages when a scroll lands here. Only that zone's pages move — the
    /// point of per-zone paging is that reading one zone leaves the others as
    /// they were.
    private var scrollRegistration: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { register(proxy) }
                .onChange(of: proxy.frame(in: .named(BarCoordinateSpace.name))) { _, _ in
                    register(proxy)
                }
                .onDisappear { router.unregister(side) }
        }
    }

    private func register(_ proxy: GeometryProxy) {
        guard pages.count > 1 else {
            router.unregister(side)
            return
        }
        let frame = proxy.frame(in: .named(BarCoordinateSpace.name))
        router.register(side, minX: frame.minX, maxX: frame.maxX) { delta in
            scrollAccumulator += delta
            // A threshold rather than one page per event: a trackpad emits a
            // stream of small deltas and paging on each would fly through every
            // page in a single gesture.
            guard abs(scrollAccumulator) >= 6 else { return }
            let step = scrollAccumulator > 0 ? 1 : -1
            scrollAccumulator = 0
            page = (page + step + pages.count) % pages.count
        }
    }
}

enum BarCoordinateSpace {
    /// Zone frames and the window's scroll location are compared in this space.
    static let name = "spaceman.bar"
}

/// A section's fill: a quad whose slanted edges are shared with its neighbours.
private struct SectionShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// Uncoloured gap rects, in bar coordinates, gathered from every zone.
struct BarHolesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct SectionWidthKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// One dot per page, the current one filled. Clicking anywhere on the cluster
/// advances to the next page; scrolling the zone steps either way.
///
/// The whole cluster is one target rather than one per dot. A 4pt dot is far
/// below the size anything should have to be clicked precisely, and "go to page
/// 3" is not worth aiming for when there are rarely more than a few pages —
/// clicking again gets there.
///
/// The dots are also the zone's scroll affordance and its minimum hit width: a
/// page whose modules render narrow — or render nothing at all, like an empty
/// status message — would otherwise leave almost nothing to aim at.
private struct PageDots: View {
    let count: Int
    let current: Int
    let context: BarContext
    let onAdvance: () -> Void

    var body: some View {
        Button(action: onAdvance) {
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(Theme.color(index == current ? .accent : .muted,
                                          in: context.palette))
                        .opacity(index == current ? 1 : 0.4)
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 6)
            // Full bar height, so the target is a comfortable strip rather than
            // a 4pt line.
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Page \(current + 1) of \(count) — click for the next, or scroll")
    }
}
