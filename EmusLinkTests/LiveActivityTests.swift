import XCTest
@testable import EmusLink

final class LiveActivityTests: XCTestCase {
    private func snapshot() -> BMSSnapshot {
        var s = BMSSnapshot()
        s.soc = 61.27; s.packVoltage = 372; s.current = -20
        return s
    }

    func testState() throws {
        let state = try XCTUnwrap(LiveActivityController.state(snapshot: snapshot(), rangeKm: 187.6, whPerKm: 154.4,
                                                               tripKm: 12.34, temperature: .normal))
        XCTAssertEqual(state.soc, 61.3)
        XCTAssertEqual(state.rangeKm, 188)
        XCTAssertEqual(state.whPerKm, 154)
        XCTAssertEqual(state.powerKW, 7.4, "ABRP convention: positive = consumption")
        XCTAssertEqual(state.tripKm, 12.3)
        XCTAssertNil(state.tempWarning)
    }

    func testStateNeedsTheSoc() {
        var s = snapshot(); s.soc = nil
        XCTAssertNil(LiveActivityController.state(snapshot: s, rangeKm: nil, whPerKm: nil, tripKm: 0, temperature: .normal))
    }

    func testTemperatureWarning() {
        let hot = LiveActivityController.state(snapshot: snapshot(), rangeKm: nil, whPerKm: nil, tripKm: 0, temperature: .hot)
        XCTAssertEqual(hot?.tempWarning, .hot)
        XCTAssertNil(hot?.rangeKm)
    }

    func testUpdateThrottling() throws {
        let a = try XCTUnwrap(LiveActivityController.state(snapshot: snapshot(), rangeKm: 100, whPerKm: 150,
                                                           tripKm: 1, temperature: .normal))
        var b = a; b.tripKm = 1.1
        var warm = a; warm.tempWarning = .hot
        XCTAssertTrue(LiveActivityController.shouldUpdate(from: nil, to: a, since: 0))
        XCTAssertFalse(LiveActivityController.shouldUpdate(from: a, to: b, since: 3))
        XCTAssertTrue(LiveActivityController.shouldUpdate(from: a, to: b, since: LiveActivityController.updateInterval))
        XCTAssertTrue(LiveActivityController.shouldUpdate(from: a, to: warm, since: 1), "a warning goes out at once")
        XCTAssertFalse(LiveActivityController.shouldUpdate(from: a, to: a, since: 60))
        XCTAssertTrue(LiveActivityController.shouldUpdate(from: a, to: a, since: LiveActivityController.refreshInterval),
                      "refreshed now and then, so it does not go stale")
    }
}
