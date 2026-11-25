import Foundation

/// Default values from the build configuration (`Config/*.xcconfig` → Info.plist).
/// This keeps personal settings out of the source code.
enum AppConfig {
    static let bundleID = Bundle.main.bundleIdentifier ?? "emuslink"
    static let defaultModuleName = string("EmusDefaultModuleName")
    static let abrpAPIKey = string("ABRPDefaultAPIKey")
    static let abrpUserToken = string("ABRPDefaultUserToken")

    private static func string(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
