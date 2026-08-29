/// AX rules that decide whether a window is a document (tileable) or an
/// overlay that must be left alone.
///
/// Mirrors the Go version's `Tileable()` plus the checks that catch Open/Save
/// panels and Xcode popups which report as ordinary windows.
public enum WindowRules {

    /// Roles that are overlays even when the subrole claims otherwise.
    public static let rejectedRoles: Set<String> = [
        "AXSheet", "AXDialog", "AXPopover", "AXSystemDialog", "AXDrawer",
    ]

    public static func isDocumentWindow(role: String?, subrole: String?,
                                        isModal: Bool, resizable: Bool,
                                        movable: Bool) -> Bool {
        if isModal { return false }
        if !resizable || !movable { return false }
        if let role, rejectedRoles.contains(role) { return false }
        return subrole == "AXStandardWindow"
    }
}
