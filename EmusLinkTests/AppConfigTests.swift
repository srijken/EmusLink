import XCTest
@testable import EmusLink

final class AppConfigTests: XCTestCase {
    func testVersionLabel() {
        XCTAssertEqual(AppConfig.versionLabel(version: "0.3", build: "3"), "0.3 (3)")
        XCTAssertEqual(AppConfig.versionLabel(version: "0.3", build: ""), "0.3")
        XCTAssertEqual(AppConfig.versionLabel(version: "", build: "3"), "3")
        XCTAssertEqual(AppConfig.versionLabel(version: "", build: ""), "–")
    }

    /// The version in `project.yml` really ends up in the app (XcodeGen writes 1.0 (1) by default).
    func testBuiltAppCarriesTheProjectVersion() {
        XCTAssertFalse(AppConfig.version.isEmpty)
        XCTAssertNotEqual(AppConfig.version, "1.0 (1)")
        XCTAssertNotNil(AppConfig.buildDate)
    }

    func testAppHasAnIcon() {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        XCTAssertEqual(primary?["CFBundleIconName"] as? String, "AppIcon")
    }
}
