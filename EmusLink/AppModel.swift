import Foundation
import CoreLocation

/// Koppelt alles aan elkaar. Bestaat één keer en wordt bij elke start aangemaakt,
/// ook als iOS de app op de achtergrond start voor Bluetooth (dan is er geen scherm).
final class AppModel {
    static let shared = AppModel()

    let store = LiveStore()
    let ble = BLEManager()
    let abrp = ABRPClient()
    let location = LocationProvider()
    let energy = EnergyTracker()

    private var lastEnergyPublish = Date.distantPast
    private var demoTimer: DispatchSourceTimer?

    private init() {
        ble.store = store
        abrp.store = store

        location.onLocation = { [energy, store] loc in
            energy.addLocation(loc)
            store.location = loc
        }

        ble.onSentence = { [weak self] snap, id in
            self?.handle(snap, id: id)
        }

        #if targetEnvironment(simulator)
        startDemo()            // geen Bluetooth in de simulator: nepdata, handig voor CarPlay
        #else
        ble.start()
        #endif

        store.energy = energy.summary()
    }

    /// Op de Bluetooth-queue, na elke geldige zin.
    private func handle(_ snap: BMSSnapshot, id: String) {
        if id == "CV1", let v = snap.packVoltage, let i = snap.current {
            energy.addPower(watts: -(v * i), charging: snap.isCharging)
        }
        abrp.maybeSend(snap, location: location.latest)

        let now = Date()
        if now.timeIntervalSince(lastEnergyPublish) >= 1 {
            lastEnergyPublish = now
            let summary = energy.summary()
            DispatchQueue.main.async { [store] in store.energy = summary }
        }
    }

    func clearHistory() {
        energy.clearHistory()
        store.energy = energy.summary()
    }

    func resetTrip() {
        energy.resetTrip()
        store.energy = energy.summary()
    }

    // MARK: - Demo (alleen simulator)

    private func startDemo() {
        var snap = BMSSnapshot()
        snap.soc = 72; snap.soh = 100; snap.capacityAh = 234
        snap.cellCount = 96; snap.cellMin = 3.86; snap.cellMax = 3.89; snap.cellAvg = 3.88
        snap.tempMin = 14; snap.tempMax = 18; snap.tempAvg = 16
        snap.firmware = "demo"
        var t = 0.0
        let timer = DispatchSource.makeTimerSource(queue: ble.queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            t += 0.5
            let speed = max(0, 70 + 40 * sin(t / 20))                     // km/h
            let kw = 18 + 25 * sin(t / 7) + (speed - 70) * 0.3             // ook negatief (regen)
            let v = 372.0 - kw * 0.4
            snap.packVoltage = v
            snap.current = -(kw * 1000 / v)
            snap.soc = max(5, (snap.soc ?? 72) - kw * 0.5 / 3600 / 82 * 100)
            snap.lastUpdate = Date()
            self.energy.addDistance(km: speed * 0.5 / 3600, speedKmh: speed)
            self.handle(snap, id: "CV1")
            let fake = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 52.09, longitude: 5.12),
                                  altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                  course: 0, speed: speed / 3.6, timestamp: Date())
            DispatchQueue.main.async { [store] in
                store.snapshot = snap
                store.connection = .connected
                store.deviceName = "Demo (simulator)"
                store.location = fake
            }
        }
        timer.resume()
        demoTimer = timer
    }
}
