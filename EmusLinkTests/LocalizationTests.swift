import XCTest
@testable import EmusLink

/// Guards the string catalogs: every string must have a Dutch translation
/// with the same placeholders as the English source.
final class LocalizationTests: XCTestCase {
    private let languages = ["nl"]

    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EmusLink/\(name).xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: [String: Any]])
    }

    private func value(_ entry: [String: Any], _ language: String) -> String? {
        let localizations = entry["localizations"] as? [String: [String: Any]]
        let unit = localizations?[language]?["stringUnit"] as? [String: Any]
        guard unit?["state"] as? String == "translated" else { return nil }
        return unit?["value"] as? String
    }

    private func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|@|\\.\\d+f|f)")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }
            .map { $0.replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression) }   // %1$@ → %@
            .sorted()
    }

    func testEveryStringIsTranslated() throws {
        let strings = try catalog("Localizable")
        XCTAssertGreaterThan(strings.count, 50)
        for (key, entry) in strings {
            XCTAssertNotEqual(entry["extractionState"] as? String, "stale", "no longer used in the code: \(key)")
            for language in languages {
                guard let translation = value(entry, language), !translation.isEmpty else {
                    XCTFail("missing \(language) translation for: \(key)"); continue
                }
                XCTAssertEqual(placeholders(translation), placeholders(key), "placeholders differ for: \(key)")
            }
        }
    }

    func testPermissionTextsAreTranslated() throws {
        let strings = try catalog("InfoPlist")
        for key in ["NSBluetoothAlwaysUsageDescription", "NSLocationWhenInUseUsageDescription",
                    "NSLocationAlwaysAndWhenInUseUsageDescription"] {
            let entry = try XCTUnwrap(strings[key], key)
            for language in ["en"] + languages {
                XCTAssertFalse((value(entry, language) ?? "").isEmpty, "\(key) in \(language)")
            }
        }
    }

    /// The built app really contains both languages.
    func testAppBundleContainsBothLanguages() throws {
        XCTAssertTrue(Bundle.main.localizations.contains("en"))
        XCTAssertTrue(Bundle.main.localizations.contains("nl"))
        let dutch = try XCTUnwrap(Bundle.main.path(forResource: "nl", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(dutch.localizedString(forKey: "Consumption", value: nil, table: nil), "Verbruik")
        XCTAssertEqual(dutch.localizedString(forKey: "Connected to %@", value: nil, table: nil), "Verbonden met %@")
    }

    func testConnectionStatesHaveLabels() {
        for state in [ConnectionState.off, .idle, .scanning, .connecting, .connected] {
            XCTAssertFalse(state.label.isEmpty)
        }
    }
}
