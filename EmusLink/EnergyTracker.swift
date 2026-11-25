import Foundation
import CoreLocation

/// Eén stukje van ~100 m rijden met de energie die daarbij uit de accu ging.
struct EnergySegment: Codable {
    var t: Date
    var km: Double
    var wh: Double
}

struct KmPoint: Identifiable {
    let id: Int          // 0 = meest recente km
    let kmAgo: Double
    let whPerKm: Double
}

struct EnergySummary {
    var tripKm: Double = 0
    var tripWh: Double = 0
    var tripStart: Date?
    var tripWhPerKm: Double?
    var last10WhPerKm: Double?
    var last100WhPerKm: Double?
    var instantWhPerKm: Double?
    var powerKW: Double = 0
    var perKm: [KmPoint] = []
    var historyKm: Double = 0
}

/// Berekent het verbruik: energie = ∫ U·I dt (uit de BMS), afstand = GPS.
/// Thread-safe: vermogen komt van de Bluetooth-queue, posities van de main thread.
final class EnergyTracker {
    private let lock = NSLock()
    private let segmentKm = 0.1
    private let maxSegments = 1000          // 1000 × 0,1 km = 100 km historie
    private let tripGap: TimeInterval = 30 * 60

    private var segments: [EnergySegment] = []
    private var segKm = 0.0, segWh = 0.0
    private var tripKm = 0.0, tripWh = 0.0
    private var tripStart: Date?
    private var lastMove = Date.distantPast

    private var lastPower: (t: Date, w: Double)?
    private var lastFix: CLLocation?
    private var speedKmh = 0.0
    private var lastSpeedTime = Date.distantPast
    private var powerW = 0.0

    private let storeKey = "energyState.v1"
    private let defaults: UserDefaults

    private struct Persisted: Codable {
        var segments: [EnergySegment]
        var tripKm: Double, tripWh: Double
        var tripStart: Date?
        var lastMove: Date
    }

    /// `defaults` is te vervangen in tests, zodat die de echte historie niet raken.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Invoer

    /// Vermogen uit de accu in watt (positief = verbruik, negatief = regen/laden).
    func addPower(watts: Double, charging: Bool, at t: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        powerW = watts
        defer { lastPower = (t, watts) }
        guard let p = lastPower else { return }
        let dt = t.timeIntervalSince(p.t)
        guard dt > 0, dt <= 5 else { return }                 // gat in de data: niet bijtellen
        if charging && currentSpeed(at: t) < 1 { return }      // laden aan de paal telt niet mee
        let wh = (p.w + watts) / 2 * dt / 3600
        segWh += wh
        if tripStart != nil { tripWh += wh }
    }

    func addLocation(_ loc: CLLocation, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 30 else { return }
        if loc.speed >= 0 { speedKmh = loc.speed * 3.6; lastSpeedTime = loc.timestamp }
        defer { lastFix = loc }
        guard let prev = lastFix else { return }
        let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
        guard dt > 0, dt < 30 else { return }
        let km = loc.distance(from: prev) / 1000
        guard km / (dt / 3600) < 200 else { return }          // GPS-sprong
        guard speedKmh > 2 || km > 0.01 else { return }       // stilstaan: GPS-ruis negeren
        // Alleen kilometers tellen als er verse BMS-data is: anders ligt de telefoon
        // niet in de Defender (fiets, andere auto) en kloppen de gemiddelden niet meer.
        guard let p = lastPower, now.timeIntervalSince(p.t) < 10 else { return }
        addDistanceLocked(km, at: loc.timestamp)
    }

    /// Voor de demo-modus in de simulator.
    func addDistance(km: Double, speedKmh s: Double, at t: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        speedKmh = s; lastSpeedTime = t
        addDistanceLocked(km, at: t)
    }

    func clearHistory() {
        lock.lock(); defer { lock.unlock() }
        segments = []; segKm = 0; segWh = 0
        tripKm = 0; tripWh = 0; tripStart = nil
        save()
    }

    func resetTrip() {
        lock.lock(); defer { lock.unlock() }
        tripKm = 0; tripWh = 0; tripStart = nil
        save()
    }

    // MARK: - Uitvoer

    func summary(at now: Date = Date()) -> EnergySummary {
        lock.lock(); defer { lock.unlock() }
        var s = EnergySummary()
        s.tripKm = tripKm
        s.tripWh = tripWh
        s.tripStart = tripStart
        s.tripWhPerKm = tripKm >= 0.5 ? tripWh / tripKm : nil
        s.last10WhPerKm = average(overKm: 10, minimumKm: 1)
        s.last100WhPerKm = average(overKm: 100, minimumKm: 20)
        s.powerKW = powerW / 1000
        let v = currentSpeed(at: now)
        s.instantWhPerKm = v > 5 ? powerW / v : nil           // W ÷ km/h = Wh/km
        s.historyKm = segments.reduce(0) { $0 + $1.km }

        // Per km, de laatste 30 km (nieuwste eerst).
        var points: [KmPoint] = []
        var km = 0.0, wh = 0.0, kmAgo = 0.0
        for seg in segments.reversed() {
            km += seg.km; wh += seg.wh
            if km >= 1 {
                points.append(KmPoint(id: points.count, kmAgo: kmAgo, whPerKm: wh / km))
                kmAgo += km; km = 0; wh = 0
                if points.count == 30 { break }
            }
        }
        s.perKm = points
        return s
    }

    // MARK: - Intern (met lock)

    private func currentSpeed(at t: Date) -> Double {
        t.timeIntervalSince(lastSpeedTime) < 10 ? speedKmh : 0
    }

    private func addDistanceLocked(_ km: Double, at t: Date) {
        if t.timeIntervalSince(lastMove) > tripGap {
            // Lang stilgestaan: nieuwe rit, en energie van het stilstaan (kachel e.d.) niet meetellen.
            tripKm = 0; tripWh = 0; tripStart = t
            segWh = 0; segKm = 0
        }
        if tripStart == nil { tripStart = t }
        lastMove = t
        segKm += km
        tripKm += km
        if segKm >= segmentKm {
            segments.append(EnergySegment(t: t, km: segKm, wh: segWh))
            if segments.count > maxSegments { segments.removeFirst(segments.count - maxSegments) }
            segKm = 0; segWh = 0
            save()
        }
    }

    private func average(overKm target: Double, minimumKm: Double) -> Double? {
        var km = segKm, wh = segWh
        for seg in segments.reversed() {
            if km >= target { break }
            km += seg.km; wh += seg.wh
        }
        return km >= minimumKm ? wh / km : nil
    }

    private func save() {
        let p = Persisted(segments: segments, tripKm: tripKm, tripWh: tripWh, tripStart: tripStart, lastMove: lastMove)
        if let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: storeKey) }
    }

    private func load() {
        guard let data = defaults.data(forKey: storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        segments = p.segments; tripKm = p.tripKm; tripWh = p.tripWh
        tripStart = p.tripStart; lastMove = p.lastMove
    }
}
