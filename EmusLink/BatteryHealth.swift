import Foundation

/// The battery measurements of one day.
struct HealthDay: Codable, Equatable {
    var soh: Double?                    // %, the last value of the day
    var restSpreadSumMv = 0.0           // sum of the cell spreads measured at rest, for the average
    var restSamples = 0
    var maxSpreadMv: Double?            // the largest cell spread of the day, also under load
    var tempMin: Double?                // °C, lowest and highest pack temperature of the day
    var tempMax: Double?

    /// The average spread between the lowest and highest cell while (almost) no current flows.
    var restSpreadMv: Double? { restSamples > 0 ? restSpreadSumMv / Double(restSamples) : nil }
}

/// One day in the health charts.
struct HealthPoint: Identifiable, Equatable {
    let date: Date
    var soh: Double?
    var restSpreadMv: Double?
    var maxSpreadMv: Double?
    var tempMin: Double?
    var tempMax: Double?
    var id: Date { date }
}

/// How far the cells are apart at rest.
enum SpreadLevel: Equatable {
    case unknown, good, watch, high
}

/// What the Insights screen shows about the battery.
struct HealthSummary: Equatable {
    var points: [HealthPoint] = []      // oldest first
    var latestSoh: Double?
    var sohChange: Double?              // percentage points between the first and the last day with a SoH
    var sohDays = 0                     // days between those two
    var recentSpreadMv: Double?         // average rest spread of the last 7 days
    var earlierSpreadMv: Double?        // average rest spread of the 30 days before that
    var level: SpreadLevel = .unknown

    /// The spread at rest has grown noticeably compared to the weeks before.
    var spreadGrowing: Bool {
        guard let recent = recentSpreadMv, let earlier = earlierSpreadMv else { return false }
        return recent - earlier >= BatteryHealth.growingMv
    }
}

/// Keeps the state of health, the cell spread and the temperatures per day,
/// so slow changes in the battery become visible. Thread-safe.
final class BatteryHealth {
    /// Below this current (A, either direction) the pack counts as at rest.
    static let restCurrentA = 3.0
    /// Rough limits for the average spread at rest (mV). The BMS reports cells in steps of 10 mV.
    static let watchMv = 40.0
    static let highMv = 80.0
    static let growingMv = 20.0
    static let recentDays = 7
    static let earlierDays = 30
    private static let keepDays = 400
    private static let saveInterval: TimeInterval = 60

    private let lock = NSLock()
    private let defaults: UserDefaults
    let calendar: Calendar

    private var days: [String: HealthDay] = [:]     // "2026-11-25" → measurements
    private var lastSave = Date.distantPast
    private let storeKey = "batteryHealth.v1"

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        load()
    }

    /// Reads the saved state again, for example after a restore from iCloud.
    func reload() {
        lock.lock(); defer { lock.unlock() }
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: storeKey),
           let stored = try? JSONDecoder().decode([String: HealthDay].self, from: data) {
            days = stored
        }
    }

    // MARK: - Input

    func addSoh(_ soh: Double, at t: Date) {
        guard soh > 0, soh <= 110 else { return }
        update(at: t) { $0.soh = soh }
    }

    /// `current` in A from the BMS; nil when unknown (then the sample does not count as rest).
    func addCells(min: Double, max: Double, current: Double?, at t: Date) {
        let spread = (max - min) * 1000
        guard spread >= 0, spread < 1000 else { return }
        update(at: t) { day in
            day.maxSpreadMv = Swift.max(day.maxSpreadMv ?? 0, spread)
            if let current, abs(current) < Self.restCurrentA {
                day.restSpreadSumMv += spread
                day.restSamples += 1
            }
        }
    }

    func addTemperatures(min: Double, max: Double, at t: Date) {
        guard min > -60, max < 120, min <= max else { return }
        update(at: t) { day in
            day.tempMin = Swift.min(day.tempMin ?? min, min)
            day.tempMax = Swift.max(day.tempMax ?? max, max)
        }
    }

    /// Writes unsaved measurements, for example when the app goes to the background.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        save(now: Date())
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        days = [:]
        save(now: Date())
    }

    // MARK: - Output

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return days.isEmpty }

    func day(_ date: Date) -> HealthDay? {
        lock.lock(); defer { lock.unlock() }
        return days[key(calendar.startOfDay(for: date))]
    }

    func summary(now: Date = Date()) -> HealthSummary {
        lock.lock(); defer { lock.unlock() }
        let dated: [(Date, HealthDay)] = days.compactMap { k, v in date(k).map { ($0, v) } }
        return Self.summarize(dated, now: now, calendar: calendar)
    }

    static func summarize(_ dated: [(Date, HealthDay)], now: Date, calendar: Calendar) -> HealthSummary {
        let sorted = dated.sorted { $0.0 < $1.0 }
        var s = HealthSummary()
        s.points = sorted.map { d, h in
            HealthPoint(date: d, soh: h.soh, restSpreadMv: h.restSpreadMv, maxSpreadMv: h.maxSpreadMv,
                        tempMin: h.tempMin, tempMax: h.tempMax)
        }

        let withSoh = sorted.filter { $0.1.soh != nil }
        s.latestSoh = withSoh.last?.1.soh
        if let first = withSoh.first, let last = withSoh.last, first.0 < last.0 {
            s.sohChange = last.1.soh! - first.1.soh!
            s.sohDays = calendar.dateComponents([.day], from: first.0, to: last.0).day ?? 0
        }

        let today = calendar.startOfDay(for: now)
        func average(from start: Int, to end: Int) -> Double? {
            // Days `start` … `end - 1` back from today, today counting as 0.
            guard let lower = calendar.date(byAdding: .day, value: -(end - 1), to: today),
                  let upper = calendar.date(byAdding: .day, value: -start, to: today) else { return nil }
            var sum = 0.0, samples = 0
            for (d, h) in sorted where d >= lower && d <= upper {
                sum += h.restSpreadSumMv; samples += h.restSamples
            }
            return samples > 0 ? sum / Double(samples) : nil
        }
        s.recentSpreadMv = average(from: 0, to: recentDays)
        s.earlierSpreadMv = average(from: recentDays, to: recentDays + earlierDays)
        s.level = level(s.recentSpreadMv)
        return s
    }

    static func level(_ spreadMv: Double?) -> SpreadLevel {
        guard let spreadMv else { return .unknown }
        return spreadMv >= highMv ? .high : spreadMv >= watchMv ? .watch : .good
    }

    // MARK: - Internal

    private func update(at t: Date, _ change: (inout HealthDay) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let k = key(calendar.startOfDay(for: t))
        let isNew = days[k] == nil
        change(&days[k, default: HealthDay()])
        if isNew { prune(now: t) }
        if isNew || t.timeIntervalSince(lastSave) >= Self.saveInterval { save(now: t) }
    }

    private func key(_ day: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func prune(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) else { return }
        let cutoffKey = key(calendar.startOfDay(for: cutoff))
        days = days.filter { $0.key >= cutoffKey }
    }

    private func save(now: Date) {
        lastSave = now
        if let data = try? JSONEncoder().encode(days) { defaults.set(data, forKey: storeKey) }
    }
}

// MARK: - Temperature warning

enum TemperatureState: Equatable {
    case normal, cold, hot
}

/// Warns when the pack gets too cold or too hot. Thread-safe.
final class TemperatureMonitor {
    static let defaultLow = 0.0
    static let defaultHigh = 45.0
    /// The temperature must come back this far (°C) inside the limits before the warning ends,
    /// so a value around the limit does not warn again and again.
    static let hysteresis = 3.0

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var current: TemperatureState = .normal

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.object(forKey: "tempAlert.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "tempAlert.enabled") }
    }

    /// Warn at or below this temperature (°C).
    var lowLimit: Double {
        get { defaults.object(forKey: "tempAlert.low") as? Double ?? Self.defaultLow }
        set { defaults.set(newValue, forKey: "tempAlert.low") }
    }

    /// Warn at or above this temperature (°C).
    var highLimit: Double {
        get { defaults.object(forKey: "tempAlert.high") as? Double ?? Self.defaultHigh }
        set { defaults.set(newValue, forKey: "tempAlert.high") }
    }

    var state: TemperatureState { lock.lock(); defer { lock.unlock() }; return current }

    /// Returns the new state when it changed, otherwise nil.
    func update(tempMin: Double, tempMax: Double) -> TemperatureState? {
        let next = enabled
            ? Self.next(from: state, tempMin: tempMin, tempMax: tempMax, low: lowLimit, high: highLimit)
            : .normal
        lock.lock(); defer { lock.unlock() }
        guard next != current else { return nil }
        current = next
        return next
    }

    static func next(from state: TemperatureState, tempMin: Double, tempMax: Double,
                     low: Double, high: Double, hysteresis: Double = hysteresis) -> TemperatureState {
        if tempMax >= high { return .hot }
        if tempMin <= low { return .cold }
        if state == .hot && tempMax > high - hysteresis { return .hot }
        if state == .cold && tempMin < low + hysteresis { return .cold }
        return .normal
    }
}
