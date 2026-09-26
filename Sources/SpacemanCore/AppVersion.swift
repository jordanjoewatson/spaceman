/// The shipping version of Spaceman.
///
/// This is the one place to bump it. `build-app.sh` copies `marketing` and
/// `build` into Info.plist so Finder, `defaults`, and `Bundle.main` agree
/// with what the bars print.
public enum AppVersion {
    /// User-facing version, e.g. the brand module and About strings.
    public static let marketing = "1.0.0"
    /// Monotonic build number written to `CFBundleVersion`.
    public static let build = 1
}
