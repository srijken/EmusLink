import XCTest
import CoreLocation
@testable import EmusLink

final class LiveStoreTests: XCTestCase {

    private func store(soc: Double? = 50, capacityAh: Double? = 234, voltage: Double? = 370) -> LiveStore {
        let s = LiveStore()
        s.snapshot.soc = soc
        s.snapshot.capacityAh = capacityAh
        s.snapshot.packVoltage = voltage
        return s
    }

    func testRemainingEnergy() {
        XCTAssertEqual(store().remainingKWh!, 43.29, accuracy: 1e-9)
        XCTAssertNil(store(soc: nil).remainingKWh)
        XCTAssertNil(store(capacityAh: nil).remainingKWh)
        XCTAssertNil(store(voltage: nil).remainingKWh)
    }

    func testRangePrefersLongestAverage() {
        let s = store()
        XCTAssertNil(s.rangeKm, "zonder verbruik geen range")
        s.energy.tripWhPerKm = 300
        XCTAssertEqual(s.rangeKm!, 43_290.0 / 300, accuracy: 1e-6)
        s.energy.last10WhPerKm = 250
        XCTAssertEqual(s.rangeKm!, 43_290.0 / 250, accuracy: 1e-6)
        s.energy.last100WhPerKm = 200
        XCTAssertEqual(s.rangeKm!, 43_290.0 / 200, accuracy: 1e-6)
    }

    func testRangeIsHiddenForImplausibleConsumption() {
        let s = store()
        s.energy.last100WhPerKm = 30          // vooral bergaf/regen: zou een absurde range geven
        XCTAssertNil(s.rangeKm)
        s.energy.last100WhPerKm = -50
        XCTAssertNil(s.rangeKm)
    }

    func testSpeedNeedsFreshValidFix() {
        let s = LiveStore()
        XCTAssertEqual(s.speedKmh, 0)
        func fix(speed: Double, age: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 52, longitude: 5), altitude: 0,
                       horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: speed,
                       timestamp: Date().addingTimeInterval(-age))
        }
        s.location = fix(speed: 25, age: 0)
        XCTAssertEqual(s.speedKmh, 90, accuracy: 1e-9)
        s.location = fix(speed: 25, age: 30)
        XCTAssertEqual(s.speedKmh, 0, "oude positie")
        s.location = fix(speed: -1, age: 0)
        XCTAssertEqual(s.speedKmh, 0, "snelheid onbekend")
    }

    func testLogKeepsNewestFirstAndIsCapped() {
        let s = LiveStore()
        for i in 0..<200 { s.addLog("regel \(i)") }
        XCTAssertEqual(s.log.count, 150)
        XCTAssertTrue(s.log.first!.hasSuffix("regel 199"))
    }
}
