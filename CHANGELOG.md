# Changelog

All notable changes to Spaceman are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Settings to show or hide the top and bottom status bars independently; a hidden bar's space goes back to tiled windows.
- Tiling exclusion list in Settings → Tiling: excluded apps are never tiled, moved or resized. Entries match by bundle ID (including the app a helper process is nested inside) or executable name, with a trailing `*` wildcard. The built-in macOS utility exclusions (System Settings, Calculator, Open/Save panels…) are now the list's defaults and can be removed.
- Lounge plugin: a fullscreen, game-controller-driven home screen. The controller's home button (or Options+Share / Menu+View) toggles it; the library of apps and websites is chosen by you in Settings → Lounge or from Lounge's Add tile, with installed games suggested while it's empty. Your own projects can be added as Docker Compose entries: Lounge brings them up, opens them in its fullscreen web view, and takes them down when you quit them, after showing the exact command on first launch. Exclude it with `./build-app.sh --without lounge`.

## [1.0.0] - 2026-09-26

### Added

- Six tiling layouts: grid, master stack, BSP, columns, rows, and monocle.
- Configurable top and bottom status bars with multi-page zones.
- Native macOS Settings interface backed by `UserDefaults`.
- Configurable global keyboard shortcuts and an in-app shortcut reference.
- Plugin system with launcher, clipboard history, focus timer, and window swap plugins.
- User-defined application and floating popup shortcuts.
- Custom bar and color palette presets.
- Focus-follows-mouse, animated window movement, and multi-display pointer navigation.
- Build-time plugin selection and notarized release build support.

[1.0.0]: https://github.com/jordanjoewatson/spaceman/releases/tag/v1.0.0
