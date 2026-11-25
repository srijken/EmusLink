import XCTest
import CoreBluetooth
@testable import EmusLink

final class BLEManagerTests: XCTestCase {
    private let other = CBUUID(string: "180F")

    func testModuleIsRecognisedByService() {
        XCTAssertTrue(BLEManager.matches(name: "", services: [other, BLEManager.serviceUUID], nameFilter: ""))
        XCTAssertTrue(BLEManager.matches(name: "Iets anders", services: [BLEManager.serviceUUID], nameFilter: "Module"))
    }

    func testModuleIsRecognisedByPartOfName() {
        XCTAssertTrue(BLEManager.matches(name: "MijnModule EMUS", services: [], nameFilter: "mijnmodule"))
        XCTAssertFalse(BLEManager.matches(name: "Koptelefoon", services: [other], nameFilter: "MijnModule"))
    }

    /// Zonder ingestelde naam mag niet elk Bluetooth-apparaat in de buurt matchen.
    func testEmptyNameFilterMatchesNothing() {
        XCTAssertFalse(BLEManager.matches(name: "Koptelefoon", services: [other], nameFilter: ""))
        XCTAssertFalse(BLEManager.matches(name: "Koptelefoon", services: [], nameFilter: "  "))
        XCTAssertFalse(BLEManager.matches(name: "", services: [], nameFilter: ""))
    }
}
