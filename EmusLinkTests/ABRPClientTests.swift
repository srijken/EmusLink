import XCTest
import CoreLocation
@testable import EmusLink

final class ABRPClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(current: Double) -> BMSSnapshot {
        var s = BMSSnapshot()
        s.soc = 60.79; s.soh = 100; s.packVoltage = 372; s.current = current; s.tempAvg = 16
        return s
    }

    private func location(speed: Double, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 52.09, longitude: 5.12), altitude: 12.7,
                   horizontalAccuracy: accuracy, verticalAccuracy: 5, course: 0, speed: speed, timestamp: now)
    }

    // MARK: - Telemetry

    func testTelemetryWhileDriving() {
        let tlm = ABRPClient.telemetry(snapshot(current: -20), soc: 60.79, location: location(speed: 25), now: now)
        XCTAssertEqual(tlm["utc"] as? Int, 1_800_000_000)
        XCTAssertEqual(tlm["soc"] as? Double, 60.8)
        XCTAssertEqual(tlm["is_charging"] as? Int, 0)
        XCTAssertEqual(tlm["power"] as? Double, 7.44, "ABRP: positive = consumption")
        XCTAssertEqual(tlm["current"] as? Double, 20, "ABRP: positive = discharging")
        XCTAssertEqual(tlm["voltage"] as? Double, 372)
        XCTAssertEqual(tlm["soh"] as? Double, 100)
        XCTAssertEqual(tlm["batt_temp"] as? Double, 16)
        XCTAssertEqual(tlm["lat"] as? Double, 52.09)
        XCTAssertEqual(tlm["lon"] as? Double, 5.12)
        XCTAssertEqual(tlm["speed"] as? Double, 90)
        XCTAssertEqual(tlm["elevation"] as? Int, 12)
        XCTAssertEqual(tlm["is_parked"] as? Int, 0)
    }

    func testTelemetryWhileCharging() {
        let tlm = ABRPClient.telemetry(snapshot(current: 30), soc: 60.79, location: location(speed: 0), now: now)
        XCTAssertEqual(tlm["is_charging"] as? Int, 1)
        XCTAssertEqual(tlm["power"] as? Double, -11.16)
        XCTAssertEqual(tlm["current"] as? Double, -30)
        XCTAssertEqual(tlm["is_parked"] as? Int, 0, "charging is not parked")
    }

    func testTelemetryParked() {
        let tlm = ABRPClient.telemetry(snapshot(current: 0), soc: 60.79, location: location(speed: 0), now: now)
        XCTAssertEqual(tlm["is_parked"] as? Int, 1)
    }

    func testTelemetryWithoutUsableLocation() {
        for loc in [nil, location(speed: 25, accuracy: -1)] {
            let tlm = ABRPClient.telemetry(snapshot(current: -20), soc: 60.79, location: loc, now: now)
            XCTAssertNil(tlm["lat"])
            XCTAssertNil(tlm["speed"])
            XCTAssertNil(tlm["is_parked"])
            XCTAssertNotNil(tlm["soc"])
        }
    }

    func testTelemetryOmitsUnknownValues() {
        var s = BMSSnapshot()
        s.soc = 50
        let tlm = ABRPClient.telemetry(s, soc: 50, location: nil, now: now)
        XCTAssertEqual(Set(tlm.keys), ["utc", "soc", "is_charging"])
    }

    // MARK: - URL

    func testURLCarriesKeyTokenAndTelemetry() throws {
        let url = try XCTUnwrap(ABRPClient.url(apiKey: "key-123", token: "tok-456", telemetry: ["soc": 60.8, "utc": 1]))
        XCTAssertTrue(url.absoluteString.hasPrefix(ABRPClient.endpoint + "?"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "api_key" }?.value, "key-123")
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "tok-456")
        let json = try XCTUnwrap(items.first { $0.name == "tlm" }?.value)
        let tlm = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(tlm["soc"] as? Double, 60.8)
    }

    /// A '+' in the token must become %2B, otherwise the server reads a space.
    func testPlusSignIsEscaped() throws {
        let url = try XCTUnwrap(ABRPClient.url(apiKey: "a+b", token: "c+d/e=", telemetry: ["soc": 1]))
        let query = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertFalse(query.contains("+"))
        XCTAssertTrue(query.contains("api_key=a%2Bb"))
        XCTAssertTrue(query.contains("token=c%2Bd"))
    }

    // MARK: - Settings

    func testSettingsAreTrimmedAndStored() {
        let suite = "EmusLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = ABRPClient(defaults: defaults, defaultAPIKey: "", defaultUserToken: "")
        XCTAssertEqual(client.apiKey, "")
        XCTAssertEqual(client.userToken, "")
        XCTAssertTrue(client.enabled, "on by default")

        client.apiKey = "  key-123\n"
        client.userToken = " tok-456 "
        client.enabled = false
        let again = ABRPClient(defaults: defaults, defaultAPIKey: "build-key", defaultUserToken: "build-token")
        XCTAssertEqual(again.apiKey, "key-123", "a saved value wins over the build configuration")
        XCTAssertEqual(again.userToken, "tok-456")
        XCTAssertFalse(again.enabled)
    }

    func testBuildConfigurationIsUsedUntilSomethingIsSaved() {
        let suite = "EmusLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = ABRPClient(defaults: defaults, defaultAPIKey: "build-key", defaultUserToken: "build-token")
        XCTAssertEqual(client.apiKey, "build-key")
        XCTAssertEqual(client.userToken, "build-token")
        client.apiKey = ""                                  // deliberately cleared in the app
        XCTAssertEqual(client.apiKey, "")
    }
}

final class ABRPQueueTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "EmusLinkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOutcome() {
        XCTAssertEqual(ABRPClient.outcome(code: 200, body: "{\"status\": \"ok\"}", networkError: false), .ok)
        XCTAssertEqual(ABRPClient.outcome(code: 0, body: "", networkError: true), .retry, "no network")
        XCTAssertEqual(ABRPClient.outcome(code: 503, body: "", networkError: false), .retry)
        XCTAssertEqual(ABRPClient.outcome(code: 429, body: "", networkError: false), .retry, "rate limit")
        XCTAssertEqual(ABRPClient.outcome(code: 401, body: "unauthorized", networkError: false), .rejected)
        XCTAssertEqual(ABRPClient.outcome(code: 200, body: "{\"status\": \"error\"}", networkError: false), .rejected)
    }

    func testQueueIsOldestFirstAndSurvivesARestart() {
        let q = TelemetryQueue(defaults: defaults)
        XCTAssertTrue(q.isEmpty)
        q.append("{\"a\":1}", utc: now)
        q.append("{\"a\":2}", utc: now.addingTimeInterval(10))
        let again = TelemetryQueue(defaults: defaults)
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(again.first?.json, "{\"a\":1}")
        again.removeFirst(ifUTC: now)
        XCTAssertEqual(again.first?.json, "{\"a\":2}")
    }

    func testRemoveFirstOnlyRemovesTheSentItem() {
        let q = TelemetryQueue(defaults: defaults)
        q.append("{}", utc: now)
        q.removeFirst(ifUTC: now.addingTimeInterval(1))
        XCTAssertEqual(q.count, 1)
    }

    func testQueueIsCapped() {
        let q = TelemetryQueue(defaults: defaults)
        for i in 0..<(TelemetryQueue.maxCount + 5) { q.append("{}", utc: now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(q.count, TelemetryQueue.maxCount)
        XCTAssertEqual(q.first?.utc, now.addingTimeInterval(5), "the oldest are dropped")
    }

    func testOldPointsArePruned() {
        let q = TelemetryQueue(defaults: defaults)
        q.append("{}", utc: now.addingTimeInterval(-TelemetryQueue.maxAge - 1))
        q.append("{}", utc: now)
        q.prune(now: now)
        XCTAssertEqual(q.count, 1)
        q.clear()
        XCTAssertTrue(TelemetryQueue(defaults: defaults).isEmpty)
    }

    func testJSONRoundTrip() {
        let json = try! XCTUnwrap(ABRPClient.json(["soc": 60.8, "utc": 1]))
        XCTAssertEqual(ABRPClient.soc(in: json), 60.8)
        let url = try! XCTUnwrap(ABRPClient.url(apiKey: "k", token: "t", json: json))
        XCTAssertTrue(url.absoluteString.contains("tlm="))
    }
}
