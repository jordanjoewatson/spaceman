import Testing
@testable import SpacemanCore

@Suite("App version")
struct AppVersionTests {

    @Test("marketing version is a dotted number the plist can carry")
    func marketingLooksLikeAVersion() {
        #expect(AppVersion.marketing.contains("."))
        #expect(AppVersion.marketing.split(separator: ".").count >= 2)
        #expect(AppVersion.build >= 1)
    }
}
