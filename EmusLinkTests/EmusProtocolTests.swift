import XCTest
@testable import EmusLink

final class EmusProtocolTests: XCTestCase {

    /// Zin met een kloppende CRC erachter.
    private func sentence(_ body: String) -> String {
        body + "," + String(format: "%02X", EmusProtocol.crc8(body + ","))
    }

    private func fields(_ body: String) -> [String] {
        body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - CRC en zinnen

    /// De verzoeken uit de logs van 22-11-2026 (zie README).
    func testRequestsMatchLoggedSentences() {
        let expected = ["BC1": "E1", "VR1": "D7", "CV1": "78", "BV1": "4F", "BT3": "CB"]
        for (id, crc) in expected {
            XCTAssertEqual(String(decoding: EmusProtocol.request(id), as: UTF8.self), "\(id),?,\(crc)\r\n")
        }
    }

    func testValidateReturnsFieldsWithoutCRC() {
        XCTAssertEqual(EmusProtocol.validate("BC1,?,E1"), ["BC1", "?"])
        XCTAssertEqual(EmusProtocol.validate(sentence("BT3,08,,76,74")), ["BT3", "08", "", "76", "74"])
    }

    func testValidateRejectsDamagedSentences() {
        XCTAssertNil(EmusProtocol.validate("BC1,?,E2"), "verkeerde CRC")
        XCTAssertNil(EmusProtocol.validate("BC1,!,E1"), "inhoud beschadigd")
        XCTAssertNil(EmusProtocol.validate("BC1,?,E"), "CRC te kort")
        XCTAssertNil(EmusProtocol.validate("BC1,?,E1A"), "CRC te lang")
        XCTAssertNil(EmusProtocol.validate("BC1,?,ZZ"), "CRC geen hex")
        XCTAssertNil(EmusProtocol.validate("BC1"), "geen komma")
        XCTAssertNil(EmusProtocol.validate(""))
    }

    // MARK: - SentenceAssembler

    func testAssemblerJoinsPacketsAndSplitsOnCRLF() {
        let a = SentenceAssembler()
        XCTAssertEqual(a.append(Data("BC1,?".utf8)), [])
        XCTAssertEqual(a.append(Data(",E1\r".utf8)), ["BC1,?,E1"])
        XCTAssertEqual(a.append(Data("\nCV1,?,78\r\nBV1,".utf8)), ["CV1,?,78"])
        XCTAssertEqual(a.append(Data("?,4F\n".utf8)), ["BV1,?,4F"])
    }

    func testAssemblerResetDropsPartialLine() {
        let a = SentenceAssembler()
        _ = a.append(Data("rommel".utf8))
        a.reset()
        XCTAssertEqual(a.append(Data("BC1,?,E1\r\n".utf8)), ["BC1,?,E1"])
    }

    func testAssemblerDropsEndlessLine() {
        let a = SentenceAssembler()
        XCTAssertEqual(a.append(Data(repeating: 0x41, count: 1025)), [])
        XCTAssertEqual(a.append(Data("BC1,?,E1\r\n".utf8)), ["BC1,?,E1"])
    }

    // MARK: - BMSSnapshot

    func testBC1ChargeCapacitySocSoh() {
        var s = BMSSnapshot()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(s.apply(fields("BC1,000798F1,000CDAA0,17BF,2710"), now: now), "BC1")
        XCTAssertEqual(s.chargeAh!, 497_905.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(s.capacityAh!, 234, accuracy: 1e-9)
        XCTAssertEqual(s.soc!, 60.79, accuracy: 1e-9)
        XCTAssertEqual(s.soh!, 100, accuracy: 1e-9)
        XCTAssertEqual(s.lastSocUpdate, now)
        XCTAssertEqual(s.lastUpdate, now)
    }

    func testCV1DischargeIsNegativeCurrentAndPositivePower() {
        var s = BMSSnapshot()
        s.apply(fields("CV1,9150,FF38"))            // 372,00 V, −20,0 A
        XCTAssertEqual(s.packVoltage!, 372, accuracy: 1e-9)
        XCTAssertEqual(s.current!, -20, accuracy: 1e-9)
        XCTAssertEqual(s.powerKW!, 7.44, accuracy: 1e-9)
        XCTAssertFalse(s.isCharging)
    }

    func testCV1ChargingIsPositiveCurrentAndNegativePower() {
        var s = BMSSnapshot()
        s.apply(fields("CV1,9150,00C8"))            // +20,0 A
        XCTAssertEqual(s.current!, 20, accuracy: 1e-9)
        XCTAssertEqual(s.powerKW!, -7.44, accuracy: 1e-9)
        XCTAssertTrue(s.isCharging)
    }

    func testSmallChargeCurrentIsNotCharging() {
        var s = BMSSnapshot()
        s.apply(fields("CV1,9150,000A"))            // +1,0 A: nog geen laden
        XCTAssertFalse(s.isCharging)
    }

    func testBV1CellVoltages() {
        var s = BMSSnapshot()
        s.apply(fields("BV1,60,BA,BD,BC,9150"))
        XCTAssertEqual(s.cellCount, 96)
        XCTAssertEqual(s.cellMin!, 3.86, accuracy: 1e-9)
        XCTAssertEqual(s.cellMax!, 3.89, accuracy: 1e-9)
        XCTAssertEqual(s.cellAvg!, 3.88, accuracy: 1e-9)
        XCTAssertEqual(s.packVoltage!, 372, accuracy: 1e-9, "packspanning uit BV1 als CV1 er nog niet is")
    }

    func testBV1DoesNotOverwritePackVoltageFromCV1() {
        var s = BMSSnapshot()
        s.apply(fields("CV1,9150,0000"))
        s.apply(fields("BV1,60,BA,BD,BC,8000"))
        XCTAssertEqual(s.packVoltage!, 372, accuracy: 1e-9)
    }

    func testBT3Temperatures() {
        var s = BMSSnapshot()
        s.apply(fields("BT3,08,72,76,74"))
        XCTAssertEqual(s.tempMin, 14)
        XCTAssertEqual(s.tempMax, 18)
        XCTAssertEqual(s.tempAvg, 16)
    }

    func testBT3BelowZero() {
        var s = BMSSnapshot()
        s.apply(fields("BT3,08,5F,64,62"))
        XCTAssertEqual(s.tempMin, -5)
        XCTAssertEqual(s.tempMax, 0)
    }

    func testVR1Firmware() {
        var s = BMSSnapshot()
        s.apply(fields("VR1,00,01,2.9.2"))
        XCTAssertEqual(s.firmware, "2.9.2")
    }

    func testUnknownSentenceIsIgnored() {
        var s = BMSSnapshot()
        XCTAssertEqual(s.apply(fields("XX9,1234")), "XX9")
        XCTAssertNil(s.lastUpdate)
        XCTAssertNil(s.apply([]))
    }

    func testShortOrGarbledSentenceKeepsOldValues() {
        var s = BMSSnapshot()
        s.apply(fields("BC1,000798F1,000CDAA0,17BF,2710"))
        s.apply(fields("BC1,000798F1"))
        s.apply(fields("BC1,xx,yy,zz,qq"))
        XCTAssertEqual(s.soc!, 60.79, accuracy: 1e-9)
        XCTAssertEqual(s.capacityAh!, 234, accuracy: 1e-9)
    }
}
