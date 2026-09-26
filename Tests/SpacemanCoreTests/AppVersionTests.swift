import Testing
@testable import SpacemanCore

@Suite("App version")
struct AppVersionTests {

    @Test("shipping marketing version is 1.0.0")
    func shippingMarketingVersion() {
        #expect(AppVersion.marketing == "1.0.0")
        #expect(AppVersion.build >= 1)
    }
}
