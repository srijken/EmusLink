import XCTest
@testable import EmusLink

final class BatteryHealthTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var calendar = Calendar(identifier: .gregorian)
    private var health: BatteryHealth!

    /// Wednesday 25 November 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_608_000)

    override func setUp() {
        suite = "EmusLinkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        health = BatteryHealth(defaults: defaults, calendar: calendar)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func day(_ back: Int) -> Date { now.addingTimeInterval(Double(-back) * 86_400) }

    // MARK: - Recording

    func testRestSpreadOnlyCountsWithoutCurrent() {
        health.addCells(min: 3.86, max: 3.88, current: 0.5, at: now)       // 20 mV at rest
        health.addCells(min: 3.86, max: 3.90, current: -2.0, at: now)      // 40 mV at rest
        health.addCells(min: 3.70, max: 3.80, current: -120, at: now)      // 100 mV under load
        health.addCells(min: 3.86, max: 3.87, current: nil, at: now)       // unknown current
        let d = try! XCTUnwrap(health.day(now))
        XCTAssertEqual(d.restSamples, 2)
        XCTAssertEqual(d.restSpreadMv!, 30, accuracy: 1e-6)
        XCTAssertEqual(d.maxSpreadMv!, 100, accuracy: 1e-6)
    }

    func testImpossibleValuesAreIgnored() {
        health.addSoh(0, at: now)
        health.addSoh(250, at: now)
        health.addCells(min: 3.9, max: 3.8, current: 0, at: now)
        health.addTemperatures(min: 30, max: 20, at: now)
        XCTAssertTrue(health.isEmpty)
    }

    func testTemperaturesKeepTheExtremesOfTheDay() {
        health.addTemperatures(min: 10, max: 15, at: now)
        health.addTemperatures(min: 8, max: 14, at: now)
        health.addTemperatures(min: 12, max: 21, at: now)
        let d = try! XCTUnwrap(health.day(now))
        XCTAssertEqual(d.tempMin, 8)
        XCTAssertEqual(d.tempMax, 21)
    }

    func testLastSohOfTheDayCounts() {
        health.addSoh(98, at: now)
        health.addSoh(97.5, at: now)
        XCTAssertEqual(health.day(now)?.soh, 97.5)
    }

    func testSavedAndLoaded() {
        health.addSoh(97, at: day(3))
        health.addCells(min: 3.8, max: 3.83, current: 0, at: day(3))
        health.flush()
        let again = BatteryHealth(defaults: defaults, calendar: calendar)
        XCTAssertEqual(again.day(day(3)), health.day(day(3)))
    }

    func testOldDaysArePruned() {
        health.addSoh(99, at: day(500))
        health.addSoh(97, at: now)
        XCTAssertNil(health.day(day(500)))
        XCTAssertNotNil(health.day(now))
    }

    // MARK: - Summary

    func testSohChange() {
        health.addSoh(98.0, at: day(40))
        health.addSoh(97.8, at: day(20))
        health.addSoh(97.5, at: day(1))
        let s = health.summary(now: now)
        XCTAssertEqual(s.latestSoh, 97.5)
        XCTAssertEqual(s.sohChange!, -0.5, accuracy: 1e-9)
        XCTAssertEqual(s.sohDays, 39)
        XCTAssertEqual(s.points.count, 3)
        XCTAssertTrue(s.points.first!.date < s.points.last!.date, "oldest first")
    }

    func testNoSohChangeFromOneDay() {
        health.addSoh(98, at: now)
        XCTAssertNil(health.summary(now: now).sohChange)
    }

    func testRecentAndEarlierSpread() {
        for back in 0..<7 { health.addCells(min: 3.8, max: 3.85, current: 0, at: day(back)) }      // 50 mV
        for back in 7..<37 { health.addCells(min: 3.8, max: 3.82, current: 0, at: day(back)) }     // 20 mV
        health.addCells(min: 3.8, max: 3.95, current: 0, at: day(40))                               // too old
        let s = health.summary(now: now)
        XCTAssertEqual(s.recentSpreadMv!, 50, accuracy: 1e-6)
        XCTAssertEqual(s.earlierSpreadMv!, 20, accuracy: 1e-6)
        XCTAssertEqual(s.level, .watch)
        XCTAssertTrue(s.spreadGrowing)
    }

    func testSpreadLevels() {
        XCTAssertEqual(BatteryHealth.level(nil), .unknown)
        XCTAssertEqual(BatteryHealth.level(20), .good)
        XCTAssertEqual(BatteryHealth.level(40), .watch)
        XCTAssertEqual(BatteryHealth.level(80), .high)
    }

    func testStableSpreadIsNotGrowing() {
        var s = HealthSummary()
        s.recentSpreadMv = 30; s.earlierSpreadMv = 20
        XCTAssertFalse(s.spreadGrowing)
        s.earlierSpreadMv = nil
        XCTAssertFalse(s.spreadGrowing)
    }

    func testClear() {
        health.addSoh(97, at: now)
        health.clear()
        XCTAssertTrue(health.isEmpty)
        XCTAssertTrue(BatteryHealth(defaults: defaults, calendar: calendar).isEmpty)
    }
}

final class TemperatureMonitorTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "EmusLinkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func next(_ state: TemperatureState, _ lo: Double, _ hi: Double) -> TemperatureState {
        TemperatureMonitor.next(from: state, tempMin: lo, tempMax: hi, low: 0, high: 45)
    }

    func testLimits() {
        XCTAssertEqual(next(.normal, 10, 30), .normal)
        XCTAssertEqual(next(.normal, 10, 45), .hot)
        XCTAssertEqual(next(.normal, 0, 10), .cold)
        XCTAssertEqual(next(.normal, -5, 50), .hot, "hot wins")
    }

    func testHysteresis() {
        XCTAssertEqual(next(.hot, 20, 43), .hot, "must drop 3 °C below the limit")
        XCTAssertEqual(next(.hot, 20, 42), .normal)
        XCTAssertEqual(next(.cold, 2, 10), .cold)
        XCTAssertEqual(next(.cold, 3, 10), .normal)
        XCTAssertEqual(next(.normal, 2, 43), .normal, "no hysteresis on the way in")
    }

    func testUpdateReportsChangesOnly() {
        let m = TemperatureMonitor(defaults: defaults)
        XCTAssertNil(m.update(tempMin: 10, tempMax: 30))
        XCTAssertEqual(m.update(tempMin: 10, tempMax: 46), .hot)
        XCTAssertNil(m.update(tempMin: 10, tempMax: 47))
        XCTAssertEqual(m.update(tempMin: 10, tempMax: 30), .normal)
    }

    func testSettingsAndDisabling() {
        let m = TemperatureMonitor(defaults: defaults)
        XCTAssertTrue(m.enabled)
        XCTAssertEqual(m.lowLimit, TemperatureMonitor.defaultLow)
        XCTAssertEqual(m.highLimit, TemperatureMonitor.defaultHigh)
        m.highLimit = 35
        XCTAssertEqual(m.update(tempMin: 10, tempMax: 36), .hot)
        m.enabled = false
        XCTAssertEqual(m.update(tempMin: 10, tempMax: 36), .normal)
        XCTAssertEqual(TemperatureMonitor(defaults: defaults).highLimit, 35)
    }

    func testWarningTexts() {
        XCTAssertNil(AlertNotifier.temperatureText(.normal, tempMin: 10, tempMax: 20, low: 0, high: 45))
        let hot = try! XCTUnwrap(AlertNotifier.temperatureText(.hot, tempMin: 10, tempMax: 46.4, low: 0, high: 45))
        XCTAssertTrue(hot.body.contains("46"))
        XCTAssertTrue(hot.body.contains("45"))
        let cold = try! XCTUnwrap(AlertNotifier.temperatureText(.cold, tempMin: -3, tempMax: 2, low: 0, high: 45))
        XCTAssertTrue(cold.body.contains("-3"))
    }
}
