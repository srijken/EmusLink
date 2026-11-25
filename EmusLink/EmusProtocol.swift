import Foundation

/// Everything to do with the serial EMUS protocol:
/// sentences such as `BC1,000798F1,000CDAA0,17BF,2710,...,A4` ending in a CRC-8.
enum EmusProtocol {

    /// CRC-8/MAXIM (Dallas 1-Wire): poly 0x31 reflected (0x8C), init 0.
    /// Calculated over everything up to and including the last comma.
    static func crc8<S: StringProtocol>(_ text: S) -> UInt8 {
        var crc: UInt8 = 0
        for byte in text.utf8 {
            crc ^= byte
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1
            }
        }
        return crc
    }

    /// Request as EVGUI sends it, for example `VR1,?,D7` + CRLF.
    static func request(_ sentence: String) -> Data {
        let body = "\(sentence),?,"
        let line = body + String(format: "%02X", crc8(body)) + "\r\n"
        return Data(line.utf8)
    }

    /// Returns the fields (without the CRC) if the checksum is correct, otherwise nil.
    static func validate(_ line: String) -> [String]? {
        guard let lastComma = line.lastIndex(of: ",") else { return nil }
        let body = line[...lastComma]
        let crcText = line[line.index(after: lastComma)...]
        guard crcText.count == 2, let expected = UInt8(crcText, radix: 16),
              crc8(body) == expected else { return nil }
        return line[..<lastComma].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Joins BLE packets (at most ~20 bytes) into whole lines.
/// Works on bytes: in a Swift String "\r\n" is a single character, so searching for "\n" fails there.
final class SentenceAssembler {
    private var buffer: [UInt8] = []

    func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A || byte == 0x0D {           // LF or CR: line complete
                if !buffer.isEmpty {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                buffer.append(byte)
                // Lost packets can produce an endless line: do not let it grow.
                if buffer.count > 1024 { buffer.removeAll(keepingCapacity: true) }
            }
        }
        return lines
    }

    func reset() { buffer.removeAll() }
}

/// The last known values from the BMS.
/// Decoding derived from the logs of 22 November 2026 (EMUS G1, firmware 2.9.2_3_967404_J1939).
struct BMSSnapshot {
    var soc: Double?            // %   (BC1 field 3, 0.01 %; matches EVGUI: 0x17BF = 60.79 %)
    var soh: Double?            // %   (BC1 field 4, 0.01 %)
    var chargeAh: Double?       // Ah  (BC1 field 1, As)
    var capacityAh: Double?     // Ah  (BC1 field 2, As; 842400 As = 234 Ah)
    var packVoltage: Double?    // V   (CV1 field 1, 0.01 V)
    var current: Double?        // A   (CV1 field 2, signed 16 bit, 0.1 A; assumption: + = charging)
    var cellCount: Int?         //     (BV1 field 1)
    var cellMin: Double?        // V   (BV1, 2.00 V + n × 0.01 V)
    var cellMax: Double?
    var cellAvg: Double?
    var tempMin: Double?        // °C  (BT3, n − 100)
    var tempMax: Double?
    var tempAvg: Double?
    var firmware: String?       // VR1
    var lastUpdate: Date?
    var lastSocUpdate: Date?

    /// Power in kW using the ABRP convention: positive = consumption, negative = charging.
    var powerKW: Double? {
        guard let v = packVoltage, let i = current else { return nil }
        return -(v * i) / 1000
    }

    var isCharging: Bool { (current ?? 0) > 1.0 }

    /// Processes one validated sentence. Returns the sentence ID (e.g. "BC1").
    @discardableResult
    mutating func apply(_ f: [String], now: Date = Date()) -> String? {
        guard let id = f.first else { return nil }
        func hex(_ i: Int) -> Int? { i < f.count ? Int(f[i], radix: 16) : nil }

        switch id {
        case "BC1":
            if let c = hex(1) { chargeAh = Double(c) / 3600 }
            if let c = hex(2) { capacityAh = Double(c) / 3600 }
            if let s = hex(3) { soc = Double(s) / 100; lastSocUpdate = now }
            if let h = hex(4) { soh = Double(h) / 100 }
        case "CV1":
            if let v = hex(1) { packVoltage = Double(v) / 100 }
            if 2 < f.count, let raw = UInt16(f[2], radix: 16) {
                current = Double(Int16(bitPattern: raw)) / 10
            }
        case "BV1":
            cellCount = hex(1)
            if let x = hex(2) { cellMin = 2.0 + Double(x) / 100 }
            if let x = hex(3) { cellMax = 2.0 + Double(x) / 100 }
            if let x = hex(4) { cellAvg = 2.0 + Double(x) / 100 }
            if packVoltage == nil, let v = hex(5) { packVoltage = Double(v) / 100 }
        case "BT3":
            if let x = hex(2) { tempMin = Double(x) - 100 }
            if let x = hex(3) { tempMax = Double(x) - 100 }
            if let x = hex(4) { tempAvg = Double(x) - 100 }
        case "VR1":
            if f.count > 3 { firmware = f[3] }
        default:
            return id
        }
        lastUpdate = now
        return id
    }
}
