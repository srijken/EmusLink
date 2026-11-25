import Foundation
import CoreLocation

/// One stretch of ~100 m of driving with the energy it took from the battery.
struct EnergySegment: Codable {
    var t: Date
    var km: Double
    var wh: Double
}

/// One point of the consumption chart: the average over a short stretch of road.
struct ConsumptionPoint: Identifiable, Equatable {
    let id: Int          // 0 = most recent
    let kmAgo: Double    // distance from now to the middle of the stretch
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
    /// The most recent segments (oldest first), enough for the longest chart range.
    var recent: [EnergySegment] = []
    var historyKm: Double = 0
}

/// Calculates consumption: energy = ∫ U·I dt (from the BMS), distance = GPS.
/// Thread-safe: power arrives on the Bluetooth queue, locations on the main thread.
final class EnergyTracker {
    private let lock = NSLock()
    private let segmentKm = 0.1
    private let maxSegments = 1000          // 1000 × 0.1 km = 100 km of history
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

    /// `defaults` can be replaced in tests, so they do not touch the real history.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Input

    /// Power drawn from the battery in watts (positive = consumption, negative = regeneration/charging).
    /// Returns what was added, with the speed at that moment; nil if nothing was counted.
    @discardableResult
    func addPower(watts: Double, charging: Bool, at t: Date = Date()) -> EnergySample? {
        lock.lock(); defer { lock.unlock() }
        powerW = watts
        defer { lastPower = (t, watts) }
        guard let p = lastPower else { return nil }
        let dt = t.timeIntervalSince(p.t)
        guard dt > 0, dt <= 5 else { return nil }                 // gap in the data: do not add
        let speed = currentSpeed(at: t)
        if charging && speed < 1 { return nil }      // charging at a charger does not count
        let wh = (p.w + watts) / 2 * dt / 3600
        segWh += wh
        if tripStart != nil { tripWh += wh }
        return EnergySample(wh: wh, km: speed * dt / 3600, speedKmh: speed)
    }

    /// Returns the kilometres that were counted (0 if the fix was ignored).
    @discardableResult
    func addLocation(_ loc: CLLocation, now: Date = Date()) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 30 else { return 0 }
        if loc.speed >= 0 { speedKmh = loc.speed * 3.6; lastSpeedTime = loc.timestamp }
        defer { lastFix = loc }
        guard let prev = lastFix else { return 0 }
        let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
        guard dt > 0, dt < 30 else { return 0 }
        let km = loc.distance(from: prev) / 1000
        guard km / (dt / 3600) < 200 else { return 0 }          // GPS jump
        guard speedKmh > 2 || km > 0.01 else { return 0 }       // standing still: ignore GPS noise
        // Only count kilometres while there is fresh BMS data: otherwise the phone is
        // not in the car (bicycle, another car) and the averages would be wrong.
        guard let p = lastPower, now.timeIntervalSince(p.t) < 10 else { return 0 }
        addDistanceLocked(km, at: loc.timestamp)
        return km
    }

    /// For the demo mode in the simulator.
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

    // MARK: - Output

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

        s.recent = Array(segments.suffix(Self.chartSegments))
        return s
    }

    // MARK: - Chart

    /// Longest range the chart can show, in km.
    static let maxChartKm = 50.0
    private static let chartSegments = 500          // 500 × ≥0.1 km ≥ 50 km

    /// The consumption curve over the last `rangeKm`, newest first, averaged per `bucketKm`
    /// so the line stays readable. `segments` are oldest first.
    static func curve(segments: [EnergySegment], rangeKm: Double, bucketKm: Double) -> [ConsumptionPoint] {
        var points: [ConsumptionPoint] = []
        var km = 0.0, wh = 0.0, kmAgo = 0.0
        for seg in segments.reversed() {
            if kmAgo + km >= rangeKm { break }
            km += seg.km; wh += seg.wh
            if km >= bucketKm - 1e-9 {
                points.append(ConsumptionPoint(id: points.count, kmAgo: kmAgo + km / 2, whPerKm: wh / km))
                kmAgo += km; km = 0; wh = 0
            }
        }
        return points
    }

    /// Average consumption over the last `rangeKm` of `segments`, or nil below `minimumKm`.
    static func average(segments: [EnergySegment], rangeKm: Double, minimumKm: Double = 0.5) -> Double? {
        var km = 0.0, wh = 0.0
        for seg in segments.reversed() {
            if km >= rangeKm { break }
            km += seg.km; wh += seg.wh
        }
        return km >= minimumKm ? wh / km : nil
    }

    // MARK: - Internal (lock held)

    private func currentSpeed(at t: Date) -> Double {
        t.timeIntervalSince(lastSpeedTime) < 10 ? speedKmh : 0
    }

    private func addDistanceLocked(_ km: Double, at t: Date) {
        if t.timeIntervalSince(lastMove) > tripGap {
            // Parked for a long time: new trip, and do not count the energy used while parked (heater etc.).
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
