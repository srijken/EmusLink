import Foundation
import CoreLocation
import UIKit

/// Sends telemetry to ABRP's Telemetry API (Iternio).
/// Same endpoint as the OVMS plugin: GET https://api.iternio.com/1/tlm/send?api_key=…&token=…&tlm={json}
/// `maybeSend` is called on the Bluetooth queue; the result goes to the LiveStore.
/// When sending fails (no network), the telemetry waits in a `TelemetryQueue` and is sent later,
/// oldest first, so ABRP still gets the whole trip and ends with the current state.
final class ABRPClient {
    static let endpoint = "https://api.iternio.com/1/tlm/send"
    /// Pause between two queued requests while catching up, so the API is not flooded.
    static let catchUpInterval: TimeInterval = 1

    weak var store: LiveStore?

    private let defaults: UserDefaults
    private let defaultAPIKey: String
    private let defaultUserToken: String
    let queue: TelemetryQueue
    private let sendQueue = DispatchQueue(label: "\(AppConfig.bundleID).abrp")

    /// The defaults come from the build configuration and apply until something is saved in the app.
    init(defaults: UserDefaults = .standard,
         defaultAPIKey: String = AppConfig.abrpAPIKey,
         defaultUserToken: String = AppConfig.abrpUserToken) {
        self.defaults = defaults
        self.defaultAPIKey = defaultAPIKey
        self.defaultUserToken = defaultUserToken
        self.queue = TelemetryQueue(defaults: defaults)
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

        guard let json = Self.json(Self.telemetry(snap, soc: soc, location: recentLoc, now: now)) else {
            finish(nil); return
        }

        if queue.isEmpty {
            send(json) { [weak self] outcome, result in
                guard let self else { return }
                if outcome == .retry { self.queue.append(json, utc: now) }
                self.finish(result, ok: outcome == .ok, sentAt: outcome == .ok ? now : nil)
            }
        } else {
            // Older points are still waiting: this one goes behind them, so ABRP ends with the newest.
            queue.append(json, utc: now)
            catchUp(lastResult: nil)
        }
    }

    /// Sends the queued telemetry one by one, oldest first, until the queue is empty or a request fails.
    private func catchUp(lastResult: (String, Bool, Date)?) {
        queue.prune(now: Date())
        guard let item = queue.first else {
            finish(lastResult?.0, ok: lastResult?.1 ?? false, sentAt: lastResult?.2)
            return
        }
        send(item.json) { [weak self] outcome, result in
            guard let self else { return }
            // No network: stop and try again with the next due point.
            if outcome == .retry { self.finish(result, ok: false); return }
            self.queue.removeFirst(ifUTC: item.utc)        // sent, or refused (sending it again will not help)
            self.publishPending()
            self.sendQueue.asyncAfter(deadline: .now() + Self.catchUpInterval) {
                self.catchUp(lastResult: (result, outcome == .ok, item.utc))
            }
        }
    }

    enum Outcome: Equatable {
        case ok         // accepted
        case retry      // no network, timeout, server error or rate limit: keep it and send it later
        case rejected   // the request itself was refused: sending it again will not help
    }

    /// Whether a failed request is worth sending again. `code` is 0 when there was no response.
    static func outcome(code: Int, body: String, networkError: Bool) -> Outcome {
        if networkError { return .retry }
        if code == 200, body.contains("\"ok\"") { return .ok }
        if code == 0 || code == 408 || code == 429 || code >= 500 { return .retry }
        return .rejected
    }

    /// One request; `completion` gets the outcome and the text for the Settings screen.
    private func send(_ json: String, completion: @escaping (Outcome, String) -> Void) {
        guard let url = Self.url(apiKey: apiKey, token: userToken, json: json) else {
            completion(.rejected, String(localized: "Error: invalid request")); return
        }
        // Ask for some extra time, so the request can finish when iOS suspends the app again.
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "abrp") {
            UIApplication.shared.endBackgroundTask(task)
        }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let outcome = Self.outcome(code: code, body: body, networkError: error != nil)
            if let error {
                completion(outcome, String(localized: "Error: \(error.localizedDescription)"))
            } else if outcome == .ok {
                let soc = Self.soc(in: json).map { String(format: "%.1f", $0) } ?? "–"
                completion(outcome, "OK (SoC \(soc) %)")
            } else {
                completion(outcome, "HTTP \(code): \(body.prefix(120))")
            }
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

    static func json(_ telemetry: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: telemetry, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func url(apiKey: String, token: String, telemetry: [String: Any]) -> URL? {
        json(telemetry).flatMap { url(apiKey: apiKey, token: token, json: $0) }
    }

    static func url(apiKey: String, token: String, json: String) -> URL? {
        guard var comps = URLComponents(string: endpoint) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "tlm", value: json),
        ]
        // URLComponents does not escape '+'; the server reads it as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    static func soc(in json: String) -> Double? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["soc"] as? NSNumber)?.doubleValue
    }

    private func finish(_ result: String?, ok: Bool = false, sentAt: Date? = nil) {
        lock.lock(); inFlight = false; lock.unlock()
        publishPending()
        guard let result else { return }
        DispatchQueue.main.async { [weak store] in
            store?.abrpResult = result
            store?.abrpOK = ok
            if let sentAt { store?.abrpLastSent = sentAt }
        }
    }

    private func publishPending() {
        let pending = queue.count
        DispatchQueue.main.async { [weak store] in store?.abrpPending = pending }
    }
}

/// Telemetry that could not be sent yet. Kept in `UserDefaults`, so it survives the app being stopped.
/// Thread-safe.
final class TelemetryQueue {
    /// At 10 s per point this is about four hours of driving.
    static let maxCount = 1500
    /// Older points are of no use to ABRP any more.
    static let maxAge: TimeInterval = 24 * 3600

    struct Item: Codable, Equatable {
        var utc: Date
        var json: String
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storeKey = "abrpQueue.v1"
    private var items: [Item] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let stored = try? JSONDecoder().decode([Item].self, from: data) {
            items = stored
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var isEmpty: Bool { count == 0 }
    var first: Item? { lock.lock(); defer { lock.unlock() }; return items.first }

    func append(_ json: String, utc: Date) {
        lock.lock(); defer { lock.unlock() }
        items.append(Item(utc: utc, json: json))
        if items.count > Self.maxCount { items.removeFirst(items.count - Self.maxCount) }
        save()
    }

    /// Removes the oldest item, if it is still the one that was sent.
    func removeFirst(ifUTC utc: Date) {
        lock.lock(); defer { lock.unlock() }
        guard items.first?.utc == utc else { return }
        items.removeFirst()
        save()
    }

    func prune(now: Date) {
        lock.lock(); defer { lock.unlock() }
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.utc) > Self.maxAge }
        if items.count != before { save() }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        items = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: storeKey) }
    }
}
