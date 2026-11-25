import Foundation
import CoreLocation

enum ConnectionState: String {
    case off = "Bluetooth uit"
    case idle = "Niet verbonden"
    case scanning = "Zoeken…"
    case connecting = "Verbinden…"
    case connected = "Verbonden"
}

/// Alles wat de schermen tonen. Wordt alleen op de main thread bijgewerkt,
/// en hooguit een paar keer per seconde, zodat de app soepel blijft.
final class LiveStore: ObservableObject {
    @Published var snapshot = BMSSnapshot()
    @Published var connection: ConnectionState = .idle
    @Published var deviceName: String?
    @Published var packets = 0
    @Published var validSentences = 0
    @Published var invalidSentences = 0
    @Published var notifyOn = false
    @Published var writeCharacteristic: String?
    @Published var log: [String] = []
    @Published var energy = EnergySummary()
    @Published var abrpResult = "Nog niets verstuurd"
    @Published var abrpLastSent: Date?
    @Published var location: CLLocation?

    var speedKmh: Double {
        guard let l = location, l.speed >= 0, Date().timeIntervalSince(l.timestamp) < 10 else { return 0 }
        return l.speed * 3.6
    }

    /// Geschatte resterende energie (kWh): SoC × capaciteit × actuele packspanning.
    var remainingKWh: Double? {
        guard let soc = snapshot.soc, let ah = snapshot.capacityAh, let v = snapshot.packVoltage else { return nil }
        return soc / 100 * ah * v / 1000
    }

    /// Geschatte range (km) op basis van het gemiddelde verbruik (100 km → 10 km → rit).
    var rangeKm: Double? {
        guard let kwh = remainingKWh,
              let whPerKm = energy.last100WhPerKm ?? energy.last10WhPerKm ?? energy.tripWhPerKm,
              whPerKm > 50 else { return nil }
        return kwh * 1000 / whPerKm
    }

    func addLog(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(text)", at: 0)
        if log.count > 150 { log.removeLast(log.count - 150) }
    }
}
