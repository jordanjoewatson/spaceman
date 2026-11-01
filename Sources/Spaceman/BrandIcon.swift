import AppKit
import SwiftUI

/// The monochrome Spaceman mark (StatusIcon.svg), loaded from the app bundle.
///
/// Drawn as a template so the menu bar and the bar module tint it like an SF
/// Symbol. Missing in a `swift run` binary (no Resources); those call sites
/// fall back to the old split-rectangle symbol.
enum BrandIcon {

    static func nsImage(pointSize: CGFloat) -> NSImage? {
        guard let source = bundled else { return nil }
        // The mark is an SVG, so a resized copy stays vector and renders
        // crisply at any backing scale.
        guard let image = source.copy() as? NSImage else { return nil }
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        image.accessibilityDescription = "Spaceman"
        return image
    }

    /// Menu-bar extra. Slightly under the system cap so it does not clip.
    static func statusItemImage() -> NSImage? {
        nsImage(pointSize: 22)
    }

    struct View: SwiftUI.View {
        var pointSize: CGFloat = 18

        var body: some SwiftUI.View {
            if let image = BrandIcon.nsImage(pointSize: pointSize) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .interpolation(.high)
                    .frame(width: pointSize, height: pointSize)
            } else {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: pointSize * 0.85))
            }
        }
    }

    /// The dedicated monochrome mark is bundled separately from the full-color
    /// Dock icon. Falling back to AppIcon keeps `swift run` and older bundles
    /// usable when the status asset is absent.
    private static var bundled: NSImage? {
        if let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(named: "AppIcon")
    }
}
