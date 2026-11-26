import Foundation

/// The energy and distance of one short interval of driving, at one speed.
struct EnergySample: Equatable {
    var wh: Double          // net energy from the battery (negative = regeneration)
    var km: Double
    var speedKmh: Double
}

/// Everything measured within one speed band (e.g. 50–60 km/h).
struct SpeedBand: Codable, Equatable {
    var km = 0.0
    var wh = 0.0            // net, regeneration already subtracted
    var regenWh = 0.0       // energy recovered, as a positive number
}

/// One point of the consumption-by-speed chart.
struct SpeedPoint: Identifiable, Equatable {
    let id: Int             // band index
    let speedKmh: Double    // middle of the band
    let whPerKm: Double
    let km: Double
}

struct SpeedSummary: Equatable {
    var points: [SpeedPoint] = []
    /// The speeds at which consumption is at most 6 % above the lowest.
    var best: ClosedRange<Double>?
    /// Consumption in the best 20 km/h band.
    var lowestWhPerKm: Double?
    var totalKm = 0.0
    /// Share of the energy used that was recovered while braking (0…1).
    var regenShare: Double?

    /// Consumption at `speed`, interpolated between the measured bands; nil outside them.
    func whPerKm(at speed: Double) -> Double? {
        guard let i = points.firstIndex(where: { $0.speedKmh >= speed }) else { return nil }
        let b = points[i]
        if b.speedKmh == speed { return b.whPerKm }
        guard i > 0 else { return nil }
        let a = points[i - 1]
        return a.whPerKm + (b.whPerKm - a.whPerKm) * (speed - a.speedKmh) / (b.speedKmh - a.speedKmh)
    }
}

/// Learns at which speed the car is most efficient: consumption per speed band,
/// including accelerating, regeneration and heating. Thread-safe.
final class SpeedProfile {
    static let bandWidth = 10.0
    static let bandCount = 16                 // 0–10 … 150 and up
    static let minimumSpeed = 10.0            // below this, consumption per km means little
    static let minimumBandKm = 1.0            // shown in the chart from here
    static let reliableBandKm = 5.0           // counts for "most efficient" from here
    static let wellMeasuredKm = 20.0          // drawn as a large point from here
    static let tolerance = 1.06

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var bands = [SpeedBand](repeating: SpeedBand(), count: SpeedProfile.bandCount)
    private var unsavedKm = 0.0
    private let storeKey = "speedProfile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Reads the saved state again, for example after a restore from iCloud.
    func reload() {
        lock.lock(); defer { lock.unlock() }
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([SpeedBand].self, from: data), saved.count == Self.bandCount {
            bands = saved
        }
    }

    func add(_ sample: EnergySample) {
        guard sample.speedKmh >= Self.minimumSpeed, sample.km > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let i = min(Int(sample.speedKmh / Self.bandWidth), Self.bandCount - 1)
        bands[i].km += sample.km
        bands[i].wh += sample.wh
        if sample.wh < 0 { bands[i].regenWh -= sample.wh }
        unsavedKm += sample.km
        if unsavedKm >= 0.5 { save() }
    }

    func summary() -> SpeedSummary {
        lock.lock(); defer { lock.unlock() }
        return Self.summarize(bands)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        bands = [SpeedBand](repeating: SpeedBand(), count: Self.bandCount)
        save()
    }

    private func save() {
        unsavedKm = 0
        if let data = try? JSONEncoder().encode(bands) { defaults.set(data, forKey: storeKey) }
    }

    // MARK: - Calculation

    static func summarize(_ bands: [SpeedBand]) -> SpeedSummary {
        var s = SpeedSummary()
        func rate(_ i: Int) -> Double { bands[i].wh / bands[i].km }
        func reliable(_ i: Int) -> Bool { bands.indices.contains(i) && bands[i].km >= reliableBandKm }

        for (i, band) in bands.enumerated() where band.km >= minimumBandKm {
            s.points.append(SpeedPoint(id: i, speedKmh: (Double(i) + 0.5) * bandWidth,
                                       whPerKm: band.wh / band.km, km: band.km))
        }
        s.totalKm = bands.reduce(0) { $0 + $1.km }
        let regen = bands.reduce(0) { $0 + $1.regenWh }
        let used = bands.reduce(0) { $0 + $1.wh } + regen
        s.regenShare = used > 0 ? regen / used : nil

        // Lowest = the best 20 km/h (two neighbouring bands), so one lucky band does not win.
        var lowest: (rate: Double, from: Int, to: Int)?
        for i in bands.indices where reliable(i) && reliable(i + 1) {
            let r = (bands[i].wh + bands[i + 1].wh) / (bands[i].km + bands[i + 1].km)
            if lowest == nil || r < lowest!.rate { lowest = (r, i, i + 1) }
        }
        if lowest == nil {
            for i in bands.indices where reliable(i) {
                if lowest == nil || rate(i) < lowest!.rate { lowest = (rate(i), i, i) }
            }
        }
        guard var best = lowest else { return s }

        // Widen to every neighbouring speed that is nearly as good.
        let limit = best.rate > 0 ? best.rate * tolerance : best.rate
        while reliable(best.from - 1), rate(best.from - 1) <= limit { best.from -= 1 }
        while reliable(best.to + 1), rate(best.to + 1) <= limit { best.to += 1 }
        s.lowestWhPerKm = best.rate
        s.best = (Double(best.from) * bandWidth)...(Double(best.to + 1) * bandWidth)
        return s
    }
}
