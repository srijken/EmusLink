import Foundation
import CoreLocation

enum ConnectionState {
    case off, idle, scanning, connecting, connected

    var label: String {
        switch self {
        case .off: String(localized: "Bluetooth off")
        case .idle: String(localized: "Not connected")
        case .scanning: String(localized: "Searching…")
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        }
    }
}

/// Everything the screens show. Only updated on the main thread,
/// and at most a few times per second, so the app stays smooth.
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
    @Published var speedProfile = SpeedSummary()
    @Published var week: [WeekdayPlan] = []
    @Published var todayKm = 0.0
    @Published var abrpResult = String(localized: "Nothing sent yet")
    @Published var abrpOK = false
    @Published var abrpLastSent: Date?
    @Published var location: CLLocation?

    var speedKmh: Double {
        guard let l = location, l.speed >= 0, Date().timeIntervalSince(l.timestamp) < 10 else { return 0 }
        return l.speed * 3.6
    }

    /// Estimated remaining energy (kWh): SoC × capacity × current pack voltage.
    var remainingKWh: Double? {
        guard let soc = snapshot.soc, let ah = snapshot.capacityAh, let v = snapshot.packVoltage else { return nil }
        return soc / 100 * ah * v / 1000
    }

    /// Estimated energy in a full battery (kWh): capacity × current pack voltage.
    var capacityKWh: Double? {
        guard let ah = snapshot.capacityAh, let v = snapshot.packVoltage else { return nil }
        return ah * v / 1000
    }

    /// The consumption to plan with: the longest average available.
    var planningWhPerKm: Double? {
        energy.last100WhPerKm ?? energy.last10WhPerKm ?? energy.tripWhPerKm
    }

    /// Estimated range (km) based on the average consumption (100 km → 10 km → trip).
    var rangeKm: Double? {
        guard let kwh = remainingKWh, let whPerKm = planningWhPerKm,
              whPerKm > 50 else { return nil }
        return kwh * 1000 / whPerKm
    }

    func addLog(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert("\(f.string(from: Date()))  \(text)", at: 0)
        if log.count > 150 { log.removeLast(log.count - 150) }
    }
}
