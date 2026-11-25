import Foundation
import CoreLocation
import UIKit

/// Sends telemetry to ABRP's Telemetry API (Iternio).
/// Same endpoint as the OVMS plugin: GET https://api.iternio.com/1/tlm/send?api_key=…&token=…&tlm={json}
/// `maybeSend` is called on the Bluetooth queue; the result goes to the LiveStore.
final class ABRPClient {
    static let endpoint = "https://api.iternio.com/1/tlm/send"

    weak var store: LiveStore?

    private let defaults: UserDefaults
    private let defaultAPIKey: String
    private let defaultUserToken: String

    /// The defaults come from the build configuration and apply until something is saved in the app.
    init(defaults: UserDefaults = .standard,
         defaultAPIKey: String = AppConfig.abrpAPIKey,
         defaultUserToken: String = AppConfig.abrpUserToken) {
        self.defaults = defaults
        self.defaultAPIKey = defaultAPIKey
        self.defaultUserToken = defaultUserToken
    }

    var apiKey: String {
        get { defaults.string(forKey: "abrpApiKey") ?? defaultAPIKey }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "abrpApiKey") }
    }
    var userToken: String {
        get { defaults.string(forKey: "abrpToken") ?? defaultUserToken }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "abrpToken") }
    }
    var enabled: Bool {
        get { defaults.object(forKey: "abrpEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "abrpEnabled") }
    }

    private let lock = NSLock()
    private var inFlight = false
    private var lastSent: Date?
    private var lastSoc: Double?
    private var lastCharging: Bool?

    /// Driving/charging: every 10 s. Parked: every 5 min, or right away when the SoC or charging state changes.
    func maybeSend(_ snap: BMSSnapshot, location: CLLocation?, now: Date = Date()) {
        guard enabled, !apiKey.isEmpty, !userToken.isEmpty, let soc = snap.soc else { return }

        let recentLoc = location.flatMap { now.timeIntervalSince($0.timestamp) < 60 ? $0 : nil }
        let speedKmh = max(0, (recentLoc?.speed ?? -1) * 3.6)
        let active = snap.isCharging || speedKmh > 3 || abs(snap.powerKW ?? 0) > 1

        lock.lock()
        let changed = soc != lastSoc || snap.isCharging != lastCharging
        let since = lastSent.map { now.timeIntervalSince($0) } ?? .infinity
        let due = since >= (active ? 10 : 300) || (changed && since >= 5)
        guard !inFlight, due else { lock.unlock(); return }
        inFlight = true
        lastSent = now
        lastSoc = soc
        lastCharging = snap.isCharging
        lock.unlock()

        guard let url = Self.url(apiKey: apiKey, token: userToken,
                                 telemetry: Self.telemetry(snap, soc: soc, location: recentLoc, now: now))
        else { finish(nil); return }

        // Ask for some extra time, so the request can finish when iOS suspends the app again.
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "abrp") {
            UIApplication.shared.endBackgroundTask(task)
        }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result: String
            var ok = false
            if let error {
                result = String(localized: "Error: \(error.localizedDescription)")
            } else if code == 200, body.contains("\"ok\"") {
                result = "OK (SoC \(String(format: "%.1f", soc)) %)"
                ok = true
            } else {
                result = "HTTP \(code): \(body.prefix(120))"
            }
            self?.finish(result, ok: ok, sentAt: now)
            UIApplication.shared.endBackgroundTask(task)
        }.resume()
    }

    /// The fields sent to ABRP. `location` must already have been checked for freshness.
    static func telemetry(_ snap: BMSSnapshot, soc: Double, location: CLLocation?, now: Date) -> [String: Any] {
        let speedKmh = max(0, (location?.speed ?? -1) * 3.6)
        var tlm: [String: Any] = [
            "utc": Int(now.timeIntervalSince1970),
            "soc": (soc * 10).rounded() / 10,
            "is_charging": snap.isCharging ? 1 : 0,
        ]
        if let p = snap.powerKW { tlm["power"] = (p * 100).rounded() / 100 }
        if let v = snap.packVoltage { tlm["voltage"] = v }
        if let i = snap.current { tlm["current"] = -i }          // ABRP: + = discharging
        if let h = snap.soh { tlm["soh"] = h }
        if let t = snap.tempAvg { tlm["batt_temp"] = t }
        if let loc = location, loc.horizontalAccuracy >= 0 {
            tlm["lat"] = loc.coordinate.latitude
            tlm["lon"] = loc.coordinate.longitude
            if loc.speed >= 0 { tlm["speed"] = (speedKmh * 10).rounded() / 10 }
            if loc.verticalAccuracy >= 0 { tlm["elevation"] = Int(loc.altitude) }
            tlm["is_parked"] = (speedKmh < 1 && !snap.isCharging) ? 1 : 0
        }
        return tlm
    }

    static func url(apiKey: String, token: String, telemetry: [String: Any]) -> URL? {
        guard let json = try? JSONSerialization.data(withJSONObject: telemetry),
              let jsonText = String(data: json, encoding: .utf8),
              var comps = URLComponents(string: endpoint) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "tlm", value: jsonText),
        ]
        // URLComponents does not escape '+'; the server reads it as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    private func finish(_ result: String?, ok: Bool = false, sentAt: Date? = nil) {
        lock.lock(); inFlight = false; lock.unlock()
        guard let result else { return }
        DispatchQueue.main.async { [weak store] in
            store?.abrpResult = result
            store?.abrpOK = ok
            store?.abrpLastSent = sentAt
        }
    }
}
