import XCTest
@testable import EmusLink

final class SpeedProfileTests: XCTestCase {

    /// Bands with `km` driven at `whPerKm`, keyed by the lower bound of the band.
    private func bands(_ data: [Int: (km: Double, whPerKm: Double)]) -> [SpeedBand] {
        var bands = [SpeedBand](repeating: SpeedBand(), count: SpeedProfile.bandCount)
        for (speed, value) in data {
            bands[speed / 10] = SpeedBand(km: value.km, wh: value.km * value.whPerKm, regenWh: 0)
        }
        return bands
    }

    private func profile() -> (SpeedProfile, UserDefaults, String) {
        let suite = "EmusLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SpeedProfile(defaults: defaults), defaults, suite)
    }

    // MARK: - Summary

    func testEmptyProfile() {
        let s = SpeedProfile.summarize(bands([:]))
        XCTAssertTrue(s.points.isEmpty)
        XCTAssertNil(s.best)
        XCTAssertNil(s.lowestWhPerKm)
        XCTAssertNil(s.regenShare)
        XCTAssertEqual(s.totalKm, 0)
    }

    func testPointsSitInTheMiddleOfTheirBand() {
        let s = SpeedProfile.summarize(bands([50: (30, 200), 80: (10, 260)]))
        XCTAssertEqual(s.points.map(\.speedKmh), [55, 85])
        XCTAssertEqual(s.points.map(\.whPerKm), [200, 260])
        XCTAssertEqual(s.totalKm, 40)
    }

    func testBandsWithTooLittleDataAreNotShown() {
        let s = SpeedProfile.summarize(bands([50: (0.5, 100), 60: (30, 200)]))
        XCTAssertEqual(s.points.map(\.speedKmh), [65])
    }

    func testBestIsTheLowestTwentyKmhBand() {
        let s = SpeedProfile.summarize(bands([
            30: (20, 260), 40: (20, 220), 50: (20, 190), 60: (20, 200), 70: (20, 230), 100: (20, 320),
        ]))
        XCTAssertEqual(s.lowestWhPerKm!, 195, accuracy: 1e-9)
        XCTAssertEqual(s.best, 50...70)
    }

    func testBestWidensToNearlyAsGoodNeighbours() {
        let s = SpeedProfile.summarize(bands([
            40: (20, 204), 50: (20, 190), 60: (20, 200), 70: (20, 206), 80: (20, 240),
        ]))
        XCTAssertEqual(s.best, 40...80, "204 and 206 are within 6 % of 195")
    }

    func testBestIgnoresBandsWithLittleData() {
        let s = SpeedProfile.summarize(bands([
            20: (2, 80), 30: (2, 90),                     // a short downhill stretch
            50: (20, 190), 60: (20, 200),
        ]))
        XCTAssertEqual(s.best, 50...70)
        XCTAssertEqual(s.points.count, 4, "still shown in the chart")
    }

    func testSingleReliableBandStillGivesAnAnswer() {
        let s = SpeedProfile.summarize(bands([80: (12, 250)]))
        XCTAssertEqual(s.best, 80...90)
        XCTAssertEqual(s.lowestWhPerKm, 250)
    }

    func testInterpolationBetweenBands() {
        let s = SpeedProfile.summarize(bands([90: (20, 300), 100: (20, 340)]))
        XCTAssertEqual(s.whPerKm(at: 100)!, 320, accuracy: 1e-9)
        XCTAssertEqual(s.whPerKm(at: 95)!, 300, accuracy: 1e-9)
        XCTAssertNil(s.whPerKm(at: 130), "no data up there")
        XCTAssertNil(s.whPerKm(at: 60), "no data down there")
    }

    // MARK: - Samples

    func testSamplesLandInTheirSpeedBand() {
        let (p, defaults, suite) = profile()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<100 { p.add(EnergySample(wh: 4, km: 0.02, speedKmh: 72)) }
        for _ in 0..<100 { p.add(EnergySample(wh: 9, km: 0.03, speedKmh: 108)) }
        let s = p.summary()
        XCTAssertEqual(s.points.map(\.speedKmh), [75, 105])
        XCTAssertEqual(s.points[0].whPerKm, 200, accuracy: 1e-6)
        XCTAssertEqual(s.points[1].whPerKm, 300, accuracy: 1e-6)
        XCTAssertEqual(s.totalKm, 5, accuracy: 1e-6)
    }

    func testCrawlingAndStandingStillAreIgnored() {
        let (p, defaults, suite) = profile()
        defer { defaults.removePersistentDomain(forName: suite) }
        p.add(EnergySample(wh: 50, km: 0, speedKmh: 0))
        p.add(EnergySample(wh: 50, km: 0.001, speedKmh: 5))
        XCTAssertEqual(p.summary().totalKm, 0)
    }

    func testVeryHighSpeedsGoInTheLastBand() {
        let (p, defaults, suite) = profile()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<50 { p.add(EnergySample(wh: 20, km: 0.05, speedKmh: 190)) }
        XCTAssertEqual(p.summary().points.map(\.speedKmh), [155])
    }

    func testRegenerationShare() {
        let (p, defaults, suite) = profile()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<80 { p.add(EnergySample(wh: 10, km: 0.02, speedKmh: 60)) }       // 800 Wh used
        for _ in 0..<20 { p.add(EnergySample(wh: -10, km: 0.02, speedKmh: 60)) }      // 200 Wh recovered
        let s = p.summary()
        XCTAssertEqual(s.regenShare!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.points[0].whPerKm, 300, accuracy: 1e-6, "net consumption")
    }

    func testProfileSurvivesRestartAndCanBeCleared() {
        let (p, defaults, suite) = profile()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<100 { p.add(EnergySample(wh: 4, km: 0.02, speedKmh: 72)) }
        XCTAssertEqual(SpeedProfile(defaults: defaults).summary().totalKm, 2, accuracy: 0.5)
        p.clear()
        XCTAssertEqual(SpeedProfile(defaults: defaults).summary().totalKm, 0)
    }

    // MARK: - From the tracker

    func testTrackerSamplesCarrySpeedAndDistance() {
        let suite = "EmusLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = EnergyTracker(defaults: defaults)
        var t = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertNil(tracker.addPower(watts: 14_400, charging: false, at: t), "first reading: nothing to integrate")
        tracker.addDistance(km: 0.02, speedKmh: 72, at: t)
        t += 1
        let sample = tracker.addPower(watts: 14_400, charging: false, at: t)
        XCTAssertEqual(sample!.wh, 4, accuracy: 1e-9)
        XCTAssertEqual(sample!.km, 0.02, accuracy: 1e-9)
        XCTAssertEqual(sample!.speedKmh, 72)

        t += 30
        XCTAssertNil(tracker.addPower(watts: 14_400, charging: false, at: t), "gap in the data")
    }
}
