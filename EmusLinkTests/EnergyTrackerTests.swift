import XCTest
import CoreLocation
@testable import EmusLink

final class EnergyTrackerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var tracker: EnergyTracker!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suiteName = "EmusLinkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tracker = EnergyTracker(defaults: defaults)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Rijdt `km` met een vast verbruik: elke seconde een BMS-meting en een stukje afstand.
    private func drive(km: Double, whPerKm: Double, speedKmh: Double = 72) {
        let stepKm = speedKmh / 3600
        let watts = whPerKm * speedKmh                 // Wh/km × km/h = W
        for _ in 0..<Int((km / stepKm).rounded()) {
            clock += 1
            tracker.addPower(watts: watts, charging: watts < 0, at: clock)
            tracker.addDistance(km: stepKm, speedKmh: speedKmh, at: clock)
        }
    }

    private func location(metersNorth: Double, speed: Double = 20, accuracy: Double = 5, at t: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 52.09 + metersNorth / 111_320, longitude: 5.12),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                   course: 0, speed: speed, timestamp: t)
    }

    // MARK: - Gemiddelden

    func testEmptyTrackerHasNoAverages() {
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 0)
        XCTAssertNil(s.tripWhPerKm)
        XCTAssertNil(s.last10WhPerKm)
        XCTAssertNil(s.last100WhPerKm)
        XCTAssertNil(s.instantWhPerKm)
        XCTAssertTrue(s.perKm.isEmpty)
    }

    func testConstantConsumption() {
        drive(km: 5, whPerKm: 200)
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 5, accuracy: 0.01)
        XCTAssertEqual(s.tripWh, 1000, accuracy: 10)
        XCTAssertEqual(s.tripWhPerKm!, 200, accuracy: 2)
        XCTAssertEqual(s.last10WhPerKm!, 200, accuracy: 2)
        XCTAssertNil(s.last100WhPerKm, "100 km-gemiddelde pas vanaf 20 km")
        XCTAssertEqual(s.historyKm, 5, accuracy: 0.11)
        XCTAssertEqual(s.instantWhPerKm!, 200, accuracy: 0.001)
        XCTAssertEqual(s.powerKW, 14.4, accuracy: 0.001)
    }

    func testAveragesNeedMinimumDistance() {
        drive(km: 0.4, whPerKm: 200)
        var s = tracker.summary(at: clock)
        XCTAssertNil(s.tripWhPerKm, "ritgemiddelde pas vanaf 0,5 km")
        XCTAssertNil(s.last10WhPerKm, "10 km-gemiddelde pas vanaf 1 km")
        drive(km: 0.8, whPerKm: 200)
        s = tracker.summary(at: clock)
        XCTAssertNotNil(s.tripWhPerKm)
        XCTAssertNotNil(s.last10WhPerKm)
    }

    func testLast10OnlyCoversRecentKilometers() {
        drive(km: 15, whPerKm: 300)
        drive(km: 10, whPerKm: 100)
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.last10WhPerKm!, 100, accuracy: 5)
        XCTAssertEqual(s.last100WhPerKm!, (15 * 300 + 10 * 100) / 25.0, accuracy: 5)
    }

    func testInstantConsumptionNeedsFreshSpeed() {
        drive(km: 1, whPerKm: 200)
        XCTAssertNotNil(tracker.summary(at: clock).instantWhPerKm)
        XCTAssertNil(tracker.summary(at: clock + 11).instantWhPerKm, "snelheid ouder dan 10 s telt niet")
    }

    // MARK: - Grafiek (verbruik per km)

    func testPerKmHasOnePointPerDrivenKilometer() {
        drive(km: 5.5, whPerKm: 200)
        let points = tracker.summary(at: clock).perKm
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.map(\.id), Array(0..<5))
        for p in points { XCTAssertEqual(p.whPerKm, 200, accuracy: 5) }
    }

    func testPerKmIsNewestFirstWithIncreasingDistance() {
        drive(km: 3, whPerKm: 300)
        drive(km: 3, whPerKm: 100)
        let points = tracker.summary(at: clock).perKm
        XCTAssertGreaterThanOrEqual(points.count, 5)
        XCTAssertEqual(points.first!.kmAgo, 0)
        XCTAssertEqual(points.first!.whPerKm, 100, accuracy: 5, "eerste punt = meest recente km")
        XCTAssertEqual(points.last!.whPerKm, 300, accuracy: 10)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertEqual(b.kmAgo - a.kmAgo, 1, accuracy: 0.15, "punten liggen ~1 km uit elkaar")
        }
    }

    func testPerKmIsEmptyBelowOneKilometer() {
        drive(km: 0.9, whPerKm: 200)
        XCTAssertTrue(tracker.summary(at: clock).perKm.isEmpty)
    }

    func testPerKmIsCappedAtThirtyKilometers() {
        drive(km: 35, whPerKm: 180)
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.perKm.count, 30)
        XCTAssertEqual(s.historyKm, 35, accuracy: 0.11)
    }

    func testPerKmIsNegativeWhileRegenerating() {
        drive(km: 2, whPerKm: -150)
        let points = tracker.summary(at: clock).perKm
        XCTAssertFalse(points.isEmpty)
        for p in points { XCTAssertEqual(p.whPerKm, -150, accuracy: 5) }
    }

    func testHistoryIsLimitedToHundredKilometers() {
        drive(km: 110, whPerKm: 200, speedKmh: 144)
        XCTAssertLessThanOrEqual(tracker.summary(at: clock).historyKm, 121)   // 1000 segmenten van 0,1–0,12 km
        XCTAssertGreaterThanOrEqual(tracker.summary(at: clock).historyKm, 99)
    }

    // MARK: - Energie

    func testGapInBMSDataIsNotIntegrated() {
        drive(km: 1, whPerKm: 200)
        let before = tracker.summary(at: clock).tripWh
        clock += 6                                              // > 5 s geen data
        tracker.addPower(watts: 50_000, charging: false, at: clock)
        XCTAssertEqual(tracker.summary(at: clock).tripWh, before, accuracy: 1e-9)
    }

    func testChargingWhileParkedIsNotCounted() {
        drive(km: 1, whPerKm: 200)
        let before = tracker.summary(at: clock).tripWh
        clock += 60                                             // snelheid is nu verlopen
        for _ in 0..<120 {
            clock += 1
            tracker.addPower(watts: -11_000, charging: true, at: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripWh, before, accuracy: 1e-9)
    }

    func testConsumptionWhileParkedCountsForTrip() {
        drive(km: 1, whPerKm: 200)
        let before = tracker.summary(at: clock).tripWh
        for _ in 0..<60 {                                       // kachel aan bij het stoplicht
            clock += 1
            tracker.addPower(watts: 3600, charging: false, at: clock)
        }
        XCTAssertGreaterThan(tracker.summary(at: clock).tripWh, before + 50)
    }

    // MARK: - Ritten

    func testNewTripStartsAfterThirtyMinutesStandingStill() {
        drive(km: 3, whPerKm: 200)
        let firstStart = tracker.summary(at: clock).tripStart
        clock += 31 * 60
        drive(km: 1, whPerKm: 100)
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 1, accuracy: 0.01)
        XCTAssertEqual(s.tripWhPerKm!, 100, accuracy: 3)
        XCTAssertNotEqual(s.tripStart, firstStart)
        XCTAssertEqual(s.historyKm, 4, accuracy: 0.25, "historie blijft bewaard")
    }

    func testShortStopKeepsTrip() {
        drive(km: 3, whPerKm: 200)
        clock += 20 * 60
        drive(km: 1, whPerKm: 200)
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 4, accuracy: 0.01)
    }

    func testResetTripKeepsHistory() {
        drive(km: 3.5, whPerKm: 200)
        tracker.resetTrip()
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 0)
        XCTAssertEqual(s.tripWh, 0)
        XCTAssertNil(s.tripStart)
        XCTAssertEqual(s.perKm.count, 3)
    }

    func testClearHistoryRemovesEverything() {
        drive(km: 3, whPerKm: 200)
        tracker.clearHistory()
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 0)
        XCTAssertEqual(s.historyKm, 0)
        XCTAssertTrue(s.perKm.isEmpty)
        XCTAssertNil(s.last10WhPerKm)
    }

    func testStateSurvivesRestart() {
        drive(km: 3, whPerKm: 200)
        let before = tracker.summary(at: clock)
        let restarted = EnergyTracker(defaults: defaults).summary(at: clock)
        XCTAssertEqual(restarted.historyKm, before.historyKm, accuracy: 1e-9)
        XCTAssertEqual(restarted.perKm.count, before.perKm.count)
        XCTAssertEqual(restarted.tripKm, before.tripKm, accuracy: 0.11)   // lopend segment wordt niet bewaard
        XCTAssertEqual(restarted.tripStart, before.tripStart)
    }

    // MARK: - GPS

    func testLocationsCountOnlyWithFreshBMSData() {
        for i in 0..<10 {
            clock += 1
            tracker.addLocation(location(metersNorth: Double(i) * 20, at: clock), now: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 0, "zonder BMS-data ligt de telefoon niet in de auto")

        for i in 10..<20 {
            clock += 1
            tracker.addPower(watts: 14_400, charging: false, at: clock)
            tracker.addLocation(location(metersNorth: Double(i) * 20, at: clock), now: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 0.2, accuracy: 0.005)
    }

    func testInaccurateLocationsAreIgnored() {
        for i in 0..<10 {
            clock += 1
            tracker.addPower(watts: 14_400, charging: false, at: clock)
            tracker.addLocation(location(metersNorth: Double(i) * 20, accuracy: 80, at: clock), now: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 0)
    }

    func testGPSJumpIsIgnored() {
        clock += 1
        tracker.addPower(watts: 14_400, charging: false, at: clock)
        tracker.addLocation(location(metersNorth: 0, at: clock), now: clock)
        clock += 1
        tracker.addPower(watts: 14_400, charging: false, at: clock)
        tracker.addLocation(location(metersNorth: 500, at: clock), now: clock)     // 1800 km/h
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 0)
    }

    func testStandingStillIgnoresGPSNoise() {
        for i in 0..<30 {
            clock += 1
            tracker.addPower(watts: 500, charging: false, at: clock)
            tracker.addLocation(location(metersNorth: Double(i % 2) * 3, speed: 0, at: clock), now: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 0)
    }
}
