import Foundation

/// A named configuration the user picks between, of which exactly one is active.
///
/// Bars and palettes work the same way, so they share this: a set compiled into
/// the app and read-only, plus any number the user creates by duplicating one.
/// Keeping built-ins out of storage is what makes "go back to the default"
/// always work, and lets a later version improve one without being shadowed
/// forever by a stored copy.
public protocol Preset: Codable, Equatable, Identifiable, Sendable {
    /// Unique across built-ins and custom presets — it is how the active one is
    /// referred to, so a duplicate would make which one you get undefined.
    var name: String { get set }
    /// True for the presets compiled in. They are never written to storage.
    var isBuiltIn: Bool { get }

    static var builtIns: [Self] { get }
    /// Fallback when the active name matches nothing, e.g. after a delete.
    static var defaultName: String { get }

    /// A user-owned copy, which is how customising a built-in starts.
    func duplicated(as newName: String) -> Self
}

public extension Preset {
    var id: String { name }
}
