import Foundation

/// What is known about one day of the week.
struct WeekdayPlan: Identifiable, Equatable {
    let weekday: Int            // Calendar weekday: 1 = Sunday … 7 = Saturday
    var setKm: Double           // entered by the driver
    var learnedKm: Double?      // from the measurements, once there are enough
    var measured: [Double]      // km on the last few of these days, newest first
    var plannedKm: Double       // what to count on: learned if available and enabled, else set
    var id: Int { weekday }
}

/// Keeps the distance driven per day and learns from it how far the car usually goes
/// on each day of the week. Thread-safe.
final class DailyDistance {
    static let defaultSetKm = 40.0
    static let measurementsPerDay = 5
    static let minimumMeasurements = 3
    private static let keepDays = 100

    private let lock = NSLock()
    private let defaults: UserDefaults
    let calendar: Calendar

    private var days: [String: Double] = [:]        // "2026-11-25" → km
    private var firstDay: Date?
    private var lastDay: Date?
    private var unsavedKm = 0.0
    private let storeKey = "dailyDistance.v1"

    private struct Persisted: Codable {
        var days: [String: Double]
        var firstDay: Date?
        var lastDay: Date?
    }

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
           let p = try? JSONDecoder().decode(Persisted.self, from: data) {
            days = p.days; firstDay = p.firstDay; lastDay = p.lastDay
            unsavedKm = 0
        }
    }

    // MARK: - Settings

    var learningEnabled: Bool {
        get { defaults.object(forKey: "learnFromTrips") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "learnFromTrips") }
    }

    /// The distance the driver expects on `weekday` (1 = Sunday … 7 = Saturday).
    func setKm(for weekday: Int) -> Double {
        let all = defaults.array(forKey: "setKmPerWeekday") as? [Double] ?? []
        return all.indices.contains(weekday - 1) ? all[weekday - 1] : Self.defaultSetKm
    }

    func setSetKm(_ km: Double, for weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        var all = (1...7).map { setKm(for: $0) }
        all[weekday - 1] = max(0, km)
        defaults.set(all, forKey: "setKmPerWeekday")
    }

    // MARK: - Input

    func add(km: Double, at t: Date) {
        guard km > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let day = calendar.startOfDay(for: t)
        if firstDay == nil || day < firstDay! { firstDay = day }
        if lastDay == nil || day > lastDay! { lastDay = day; prune() }
        days[key(day), default: 0] += km
        unsavedKm += km
        if unsavedKm >= 0.2 { save() }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        days = [:]; firstDay = nil; lastDay = nil
        save()
    }

    // MARK: - Output

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return days.isEmpty }

    func km(on date: Date) -> Double {
        lock.lock(); defer { lock.unlock() }
        return days[key(calendar.startOfDay(for: date))] ?? 0
    }

    /// One entry per day of the week, starting on the calendar's first weekday.
    func plan(now: Date = Date()) -> [WeekdayPlan] {
        lock.lock(); defer { lock.unlock() }
        let learning = learningEnabled
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            let measured = measuredLocked(weekday: weekday, now: now)
            let learned = Self.learned(from: measured)
            let set = setKm(for: weekday)
            return WeekdayPlan(weekday: weekday, setKm: set, learnedKm: learned, measured: measured,
                               plannedKm: learning ? (learned ?? set) : set)
        }
    }

    /// The learned distance: a cautious "usual" day, the value that covers about three out of four days.
    /// Nil until there are enough measurements.
    static func learned(from measured: [Double]) -> Double? {
        guard measured.count >= minimumMeasurements else { return nil }
        let sorted = measured.sorted()
        return sorted[Int(0.75 * Double(sorted.count - 1))]
    }

    // MARK: - Internal (lock held)

    /// Completed days only: today is still being driven. Days without driving count as 0 km.
    private func measuredLocked(weekday: Int, now: Date) -> [Double] {
        guard let first = firstDay else { return [] }
        var result: [Double] = []
        var day = calendar.startOfDay(for: now)
        while result.count < Self.measurementsPerDay {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day), previous >= first else { break }
            day = previous
            if calendar.component(.weekday, from: day) == weekday { result.append(days[key(day)] ?? 0) }
        }
        return result
    }

    private func key(_ day: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func prune() {
        guard let last = lastDay, let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: last) else { return }
        let cutoffKey = key(cutoff)
        days = days.filter { $0.key >= cutoffKey }
        if let first = firstDay, first < cutoff { firstDay = cutoff }
    }

    private func save() {
        unsavedKm = 0
        let p = Persisted(days: days, firstDay: firstDay, lastDay: lastDay)
        if let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: storeKey) }
    }
}

/// How much charge a distance needs.
enum ChargeAdvice {
    static let reservePercent = 10.0

    /// The state of charge (%) needed to drive `km`, including the reserve; at most 100.
    static func neededSoc(km: Double, whPerKm: Double, capacityKWh: Double,
                          reserve: Double = reservePercent) -> Double? {
        guard km >= 0, whPerKm > 0, capacityKWh > 0 else { return nil }
        return min(100, km * whPerKm / 1000 / capacityKWh * 100 + reserve)
    }
}
