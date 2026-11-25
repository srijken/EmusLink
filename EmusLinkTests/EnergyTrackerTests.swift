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

    /// Drives `km` at a fixed consumption: a BMS reading and a bit of distance every second.
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

    /// The chart points as the consumption screen asks for them.
    private func curve(rangeKm: Double = 10, bucketKm: Double = 1) -> [ConsumptionPoint] {
        EnergyTracker.curve(segments: tracker.summary(at: clock).recent, rangeKm: rangeKm, bucketKm: bucketKm)
    }

    // MARK: - Averages

    func testEmptyTrackerHasNoAverages() {
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 0)
        XCTAssertNil(s.tripWhPerKm)
        XCTAssertNil(s.last10WhPerKm)
        XCTAssertNil(s.last100WhPerKm)
        XCTAssertNil(s.instantWhPerKm)
        XCTAssertTrue(s.recent.isEmpty)
    }

    func testConstantConsumption() {
        drive(km: 5, whPerKm: 200)
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 5, accuracy: 0.01)
        XCTAssertEqual(s.tripWh, 1000, accuracy: 10)
        XCTAssertEqual(s.tripWhPerKm!, 200, accuracy: 2)
        XCTAssertEqual(s.last10WhPerKm!, 200, accuracy: 2)
        XCTAssertNil(s.last100WhPerKm, "100 km average only from 20 km")
        XCTAssertEqual(s.historyKm, 5, accuracy: 0.11)
        XCTAssertEqual(s.instantWhPerKm!, 200, accuracy: 0.001)
        XCTAssertEqual(s.powerKW, 14.4, accuracy: 0.001)
    }

    func testAveragesNeedMinimumDistance() {
        drive(km: 0.4, whPerKm: 200)
        var s = tracker.summary(at: clock)
        XCTAssertNil(s.tripWhPerKm, "trip average only from 0.5 km")
        XCTAssertNil(s.last10WhPerKm, "10 km average only from 1 km")
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
        XCTAssertNil(tracker.summary(at: clock + 11).instantWhPerKm, "speed older than 10 s does not count")
    }

    // MARK: - Chart (consumption per km)

    func testCurveHasOnePointPerBucket() {
        drive(km: 5.5, whPerKm: 200)
        let points = curve(bucketKm: 1)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.map(\.id), Array(0..<5))
        for p in points { XCTAssertEqual(p.whPerKm, 200, accuracy: 5) }
    }

    func testCurveIsNewestFirstWithIncreasingDistance() {
        drive(km: 3, whPerKm: 300)
        drive(km: 3, whPerKm: 100)
        let points = curve(bucketKm: 1)
        XCTAssertGreaterThanOrEqual(points.count, 5)
        XCTAssertEqual(points.first!.kmAgo, 0.5, accuracy: 0.1, "a point sits in the middle of its stretch")
        XCTAssertEqual(points.first!.whPerKm, 100, accuracy: 5, "first point = most recent km")
        XCTAssertEqual(points.last!.whPerKm, 300, accuracy: 10)
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertEqual(b.kmAgo - a.kmAgo, 1, accuracy: 0.15, "points are ~1 km apart")
        }
    }

    func testCurveUsesFinerBucketsForShortRanges() {
        drive(km: 4, whPerKm: 200)
        let fine = curve(bucketKm: 0.2)
        XCTAssertGreaterThanOrEqual(fine.count, 15)
        XCTAssertLessThanOrEqual(fine.count, 20)
        for (a, b) in zip(fine, fine.dropFirst()) {
            XCTAssertEqual(b.kmAgo - a.kmAgo, 0.2, accuracy: 0.05)
        }
    }

    func testCurveIsEmptyBelowOneBucket() {
        drive(km: 0.9, whPerKm: 200)
        XCTAssertTrue(curve(bucketKm: 1).isEmpty)
        XCTAssertFalse(curve(bucketKm: 0.2).isEmpty)
    }

    func testCurveIsLimitedToTheRange() {
        drive(km: 35, whPerKm: 180)
        let ten = curve(rangeKm: 10, bucketKm: 0.2)
        XCTAssertLessThanOrEqual(ten.last!.kmAgo, 10)
        XCTAssertGreaterThan(ten.last!.kmAgo, 9.5)
        let twentyFive = curve(rangeKm: 25, bucketKm: 0.5)
        XCTAssertLessThanOrEqual(twentyFive.last!.kmAgo, 25)
        XCTAssertGreaterThan(twentyFive.last!.kmAgo, 24)
    }

    func testCurveCanCoverFiftyKilometers() {
        drive(km: 60, whPerKm: 180, speedKmh: 144)
        let points = curve(rangeKm: EnergyTracker.maxChartKm, bucketKm: 1)
        XCTAssertGreaterThan(points.last!.kmAgo, 48)
        XCTAssertLessThanOrEqual(points.last!.kmAgo, 50)
    }

    func testCurveIsNegativeWhileRegenerating() {
        drive(km: 2, whPerKm: -150)
        let points = curve(bucketKm: 0.2).dropLast()        // the very first reading carries no energy yet
        XCTAssertFalse(points.isEmpty)
        for p in points { XCTAssertEqual(p.whPerKm, -150, accuracy: 5) }
    }

    func testAverageOverChartRange() {
        drive(km: 15, whPerKm: 300)
        drive(km: 10, whPerKm: 100)
        let recent = tracker.summary(at: clock).recent
        XCTAssertEqual(EnergyTracker.average(segments: recent, rangeKm: 10)!, 100, accuracy: 5)
        XCTAssertEqual(EnergyTracker.average(segments: recent, rangeKm: 25)!, (15 * 300 + 10 * 100) / 25.0, accuracy: 5)
        XCTAssertEqual(EnergyTracker.average(segments: recent, rangeKm: 50)!, (15 * 300 + 10 * 100) / 25.0, accuracy: 5,
                       "a longer range than the history uses what there is")
    }

    func testAverageNeedsMinimumDistance() {
        drive(km: 0.3, whPerKm: 200)
        XCTAssertNil(EnergyTracker.average(segments: tracker.summary(at: clock).recent, rangeKm: 10))
        XCTAssertNil(EnergyTracker.average(segments: [], rangeKm: 10))
    }

    func testHistoryIsLimitedToHundredKilometers() {
        drive(km: 110, whPerKm: 200, speedKmh: 144)
        XCTAssertLessThanOrEqual(tracker.summary(at: clock).historyKm, 121)   // 1000 segments of 0.1–0.12 km
        XCTAssertGreaterThanOrEqual(tracker.summary(at: clock).historyKm, 99)
    }

    // MARK: - Energy

    func testGapInBMSDataIsNotIntegrated() {
        drive(km: 1, whPerKm: 200)
        let before = tracker.summary(at: clock).tripWh
        clock += 6                                              // > 5 s without data
        tracker.addPower(watts: 50_000, charging: false, at: clock)
        XCTAssertEqual(tracker.summary(at: clock).tripWh, before, accuracy: 1e-9)
    }

    func testChargingWhileParkedIsNotCounted() {
        drive(km: 1, whPerKm: 200)
        let before = tracker.summary(at: clock).tripWh
        clock += 60                                             // speed has expired by now
        for _ in 0..<120 {
            clock += 1
            tracker.addPower(watts: -11_000, charging: true, at: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripWh, before, accuracy: 1e-9)
    }

    func testConsumptionWhileParkedCountsForTrip() {
        drive(km: 1, whPerKm: 200)
        let before = tracker.summary(at: clock).tripWh
        for _ in 0..<60 {                                       // heater on at the traffic light
            clock += 1
            tracker.addPower(watts: 3600, charging: false, at: clock)
        }
        XCTAssertGreaterThan(tracker.summary(at: clock).tripWh, before + 50)
    }

    // MARK: - Trips

    func testNewTripStartsAfterThirtyMinutesStandingStill() {
        drive(km: 3, whPerKm: 200)
        let firstStart = tracker.summary(at: clock).tripStart
        clock += 31 * 60
        drive(km: 1, whPerKm: 100)
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 1, accuracy: 0.01)
        XCTAssertEqual(s.tripWhPerKm!, 100, accuracy: 3)
        XCTAssertNotEqual(s.tripStart, firstStart)
        XCTAssertEqual(s.historyKm, 4, accuracy: 0.25, "history is kept")
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
        XCTAssertEqual(curve().count, 3)
    }

    func testClearHistoryRemovesEverything() {
        drive(km: 3, whPerKm: 200)
        tracker.clearHistory()
        let s = tracker.summary(at: clock)
        XCTAssertEqual(s.tripKm, 0)
        XCTAssertEqual(s.historyKm, 0)
        XCTAssertTrue(s.recent.isEmpty)
        XCTAssertNil(s.last10WhPerKm)
    }

    func testStateSurvivesRestart() {
        drive(km: 3, whPerKm: 200)
        let before = tracker.summary(at: clock)
        let restarted = EnergyTracker(defaults: defaults).summary(at: clock)
        XCTAssertEqual(restarted.historyKm, before.historyKm, accuracy: 1e-9)
        XCTAssertEqual(restarted.recent.count, before.recent.count)
        XCTAssertEqual(restarted.tripKm, before.tripKm, accuracy: 0.11)   // the open segment is not persisted
        XCTAssertEqual(restarted.tripStart, before.tripStart)
    }

    // MARK: - GPS

    func testLocationsCountOnlyWithFreshBMSData() {
        for i in 0..<10 {
            clock += 1
            tracker.addLocation(location(metersNorth: Double(i) * 20, at: clock), now: clock)
        }
        XCTAssertEqual(tracker.summary(at: clock).tripKm, 0, "without BMS data the phone is not in the car")

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
