import Foundation

/// Alles wat met het seriële EMUS-protocol te maken heeft:
/// zinnen als `BC1,000798F1,000CDAA0,17BF,2710,...,A4` met een CRC-8 aan het eind.
enum EmusProtocol {

    /// CRC-8/MAXIM (Dallas 1-Wire): poly 0x31 gereflecteerd (0x8C), init 0.
    /// Berekend over alles tot en met de laatste komma.
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

    /// Verzoek zoals EVGUI het stuurt, bijvoorbeeld `VR1,?,D7` + CRLF.
    static func request(_ sentence: String) -> Data {
        let body = "\(sentence),?,"
        let line = body + String(format: "%02X", crc8(body)) + "\r\n"
        return Data(line.utf8)
    }

    /// Geeft de velden terug (zonder de CRC) als de checksum klopt, anders nil.
    static func validate(_ line: String) -> [String]? {
        guard let lastComma = line.lastIndex(of: ",") else { return nil }
        let body = line[...lastComma]
        let crcText = line[line.index(after: lastComma)...]
        guard crcText.count == 2, let expected = UInt8(crcText, radix: 16),
              crc8(body) == expected else { return nil }
        return line[..<lastComma].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Plakt BLE-pakketjes (max ~20 bytes) aan elkaar tot hele regels.
/// Werkt op bytes: in een Swift-String is "\r\n" één teken, dus zoeken naar "\n" faalt daar.
final class SentenceAssembler {
    private var buffer: [UInt8] = []

    func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A || byte == 0x0D {           // LF of CR: regel klaar
                if !buffer.isEmpty {
                    lines.append(String(decoding: buffer, as: UTF8.self))
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                buffer.append(byte)
                // Verloren pakketjes kunnen een eindeloze regel opleveren: niet laten groeien.
                if buffer.count > 1024 { buffer.removeAll(keepingCapacity: true) }
            }
        }
        return lines
    }

    func reset() { buffer.removeAll() }
}

/// De laatst bekende waarden van de BMS.
/// Decodering afgeleid uit de logs van 22-11-2026 (EMUS G1, firmware 2.9.2_3_967404_J1939).
struct BMSSnapshot {
    var soc: Double?            // %   (BC1 veld 3, 0,01 %; klopt met EVGUI: 0x17BF = 60,79 %)
    var soh: Double?            // %   (BC1 veld 4, 0,01 %)
    var chargeAh: Double?       // Ah  (BC1 veld 1, As)
    var capacityAh: Double?     // Ah  (BC1 veld 2, As; 842400 As = 234 Ah)
    var packVoltage: Double?    // V   (CV1 veld 1, 0,01 V)
    var current: Double?        // A   (CV1 veld 2, signed 16 bit, 0,1 A; aanname: + = laden)
    var cellCount: Int?         //     (BV1 veld 1)
    var cellMin: Double?        // V   (BV1, 2,00 V + n × 0,01 V)
    var cellMax: Double?
    var cellAvg: Double?
    var tempMin: Double?        // °C  (BT3, n − 100)
    var tempMax: Double?
    var tempAvg: Double?
    var firmware: String?       // VR1
    var lastUpdate: Date?
    var lastSocUpdate: Date?

    /// Vermogen in kW met de ABRP-conventie: positief = verbruik, negatief = laden.
    var powerKW: Double? {
        guard let v = packVoltage, let i = current else { return nil }
        return -(v * i) / 1000
    }

    var isCharging: Bool { (current ?? 0) > 1.0 }

    /// Verwerkt één gevalideerde zin. Geeft het zin-ID terug (bijv. "BC1").
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
