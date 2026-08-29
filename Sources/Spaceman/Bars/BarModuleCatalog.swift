import Foundation
import SpacemanCore

/// Every bar module this build can render: the core's, then whatever the loaded
/// plugins contribute.
///
/// The single place the two sets are joined, so the editor's picker and the
/// chip labels agree without either knowing that plugins exist.
@MainActor
enum BarModuleCatalog {

    static var available: [BarModuleDescriptor] {
        BarModule.core + PluginSurface.shared.barDescriptors
    }

    /// How a module reads in the editor.
    ///
    /// A module from a plugin that isn't in this build has no descriptor, so it
    /// shows its raw identifier. That is deliberate: the chip stays visible and
    /// keeps its place in the preset, making it obvious that something is
    /// referenced but unavailable rather than silently dropping it.
    static func title(for module: BarModule) -> String {
        available.first { $0.module == module }?.title ?? module.id
    }
}
