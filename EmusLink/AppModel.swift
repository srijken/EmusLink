import Foundation
import CoreLocation

/// Ties everything together. Exists once and is created on every launch,
/// also when iOS launches the app in the background for Bluetooth (there is no UI then).
final class AppModel {
    static let shared = AppModel()

    let store = LiveStore()
    let ble = BLEManager()
    let abrp = ABRPClient()
    let location = LocationProvider()
    let energy = EnergyTracker()
    let speedProfile = SpeedProfile()
    let daily = DailyDistance()

    private var lastEnergyPublish = Date.distantPast
    private var demoTimer: DispatchSourceTimer?

    private init() {
        ble.store = store
        abrp.store = store

        location.onLocation = { [energy, daily, store] loc in
            let km = energy.addLocation(loc)
            daily.add(km: km, at: loc.timestamp)
            store.location = loc
        }

        ble.onSentence = { [weak self] snap, id in
            self?.handle(snap, id: id)
        }

        #if targetEnvironment(simulator)
        startDemo()            // no Bluetooth in the simulator: demo data, handy for CarPlay
        #else
        ble.start()
        #endif

        store.energy = energy.summary()
        refreshInsights()
    }

    /// On the Bluetooth queue, after every valid sentence.
    private func handle(_ snap: BMSSnapshot, id: String) {
        if id == "CV1", let v = snap.packVoltage, let i = snap.current {
            if let sample = energy.addPower(watts: -(v * i), charging: snap.isCharging) {
                speedProfile.add(sample)
            }
        }
        abrp.maybeSend(snap, location: location.latest)

        let now = Date()
        if now.timeIntervalSince(lastEnergyPublish) >= 1 {
            lastEnergyPublish = now
            let summary = energy.summary()
            let speeds = speedProfile.summary()
            let week = daily.plan(now: now)
            let today = daily.km(on: now)
            DispatchQueue.main.async { [store] in
                store.energy = summary
                store.speedProfile = speeds
                store.week = week
                store.todayKm = today
            }
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

    // MARK: - Insights

    /// On the main thread, after a setting changed.
    func refreshInsights() {
        let now = Date()
        store.speedProfile = speedProfile.summary()
        store.week = daily.plan(now: now)
        store.todayKm = daily.km(on: now)
    }

    func setLearning(_ on: Bool) {
        daily.learningEnabled = on
        refreshInsights()
    }

    func setSetKm(_ km: Double, for weekday: Int) {
        daily.setSetKm(km, for: weekday)
        refreshInsights()
    }

    func clearInsights() {
        speedProfile.clear()
        daily.clear()
        refreshInsights()
    }

    // MARK: - Demo (simulator only)

    private func startDemo() {
        var snap = BMSSnapshot()
        snap.soc = 72; snap.soh = 100; snap.capacityAh = 234
        snap.cellCount = 96; snap.cellMin = 3.86; snap.cellMax = 3.89; snap.cellAvg = 3.88
        snap.tempMin = 14; snap.tempMax = 18; snap.tempAvg = 16
        snap.firmware = "demo"
        seedDemoDays()
        var t = 0.0
        let timer = DispatchSource.makeTimerSource(queue: ble.queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            t += 0.5
            let speed = max(0, 70 + 40 * sin(t / 20))                     // km/h
            let kw = 18 + 25 * sin(t / 7) + (speed - 70) * 0.3             // also negative (regeneration)
            let v = 372.0 - kw * 0.4
            snap.packVoltage = v
            snap.current = -(kw * 1000 / v)
            snap.soc = max(5, (snap.soc ?? 72) - kw * 0.5 / 3600 / 82 * 100)
            snap.lastUpdate = Date()
            self.energy.addDistance(km: speed * 0.5 / 3600, speedKmh: speed)
            self.daily.add(km: speed * 0.5 / 3600, at: Date())
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

    /// Five weeks of made-up days, so the weekly table shows something in the simulator.
    private func seedDemoDays() {
        guard daily.isEmpty else { return }
        let usual: [Double] = [30, 120, 40, 40, 35, 25, 80]          // Sunday … Saturday
        for back in 1...35 {
            guard let day = daily.calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let weekday = daily.calendar.component(.weekday, from: day)
            let km = back % 9 == 0 ? 0 : usual[weekday - 1] + Double((back * 37) % 23) - 8
            daily.add(km: km, at: day)
        }
    }
}
