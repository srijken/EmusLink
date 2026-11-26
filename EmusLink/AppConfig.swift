import Foundation

/// Default values from the build configuration (`Config/*.xcconfig` → Info.plist).
/// This keeps personal settings out of the source code.
enum AppConfig {
    static let bundleID = Bundle.main.bundleIdentifier ?? "emuslink"
    static let defaultModuleName = string("EmusDefaultModuleName")
    static let abrpAPIKey = string("ABRPDefaultAPIKey")
    static let abrpUserToken = string("ABRPDefaultUserToken")

    /// Version and build number, e.g. "0.3 (3)".
    static let version = versionLabel(version: string("CFBundleShortVersionString"), build: string("CFBundleVersion"))

    /// When this build was made: tells two installs of the app apart.
    static let buildDate: Date? = {
        guard let url = Bundle.main.executableURL else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }()

    static func versionLabel(version: String, build: String) -> String {
        if version.isEmpty { return build.isEmpty ? "–" : build }
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private static func string(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
