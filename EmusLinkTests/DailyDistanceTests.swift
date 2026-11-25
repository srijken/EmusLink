import XCTest
@testable import EmusLink

final class DailyDistanceTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var calendar = Calendar(identifier: .gregorian)
    private var daily: DailyDistance!

    /// Wednesday 25 November 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_608_000)

    override func setUp() {
        suite = "EmusLinkTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2                       // Monday
        daily = DailyDistance(defaults: defaults, calendar: calendar)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func day(_ back: Int) -> Date { now.addingTimeInterval(Double(-back) * 86_400) }
    private func plan(_ weekday: Int) -> WeekdayPlan { daily.plan(now: now).first { $0.weekday == weekday }! }

    private let sunday = 1, monday = 2, tuesday = 3, wednesday = 4

    func testNowIsAWednesday() {
        XCTAssertEqual(calendar.component(.weekday, from: now), wednesday)
    }

    // MARK: - Learning

    func testLearnedIsACautiousUsualDay() {
        XCTAssertEqual(DailyDistance.learned(from: [122, 126, 124, 122, 117]), 124)
        XCTAssertEqual(DailyDistance.learned(from: [34, 78, 32, 31]), 34)
        XCTAssertEqual(DailyDistance.learned(from: [134, 91, 42, 0]), 91)
        XCTAssertEqual(DailyDistance.learned(from: [20, 30, 40]), 30)
    }

    func testLearnedNeedsThreeMeasurements() {
        XCTAssertNil(DailyDistance.learned(from: []))
        XCTAssertNil(DailyDistance.learned(from: [50, 60]))
    }

    // MARK: - Plan

    func testEmptyPlanUsesSetDistances() {
        let week = daily.plan(now: now)
        XCTAssertEqual(week.map(\.weekday), [2, 3, 4, 5, 6, 7, 1], "starts on Monday")
        for d in week {
            XCTAssertEqual(d.setKm, DailyDistance.defaultSetKm)
            XCTAssertNil(d.learnedKm)
            XCTAssertTrue(d.measured.isEmpty)
            XCTAssertEqual(d.plannedKm, DailyDistance.defaultSetKm)
        }
    }

    func testMeasuredAreTheLastSameWeekdaysNewestFirst() {
        daily.add(km: 100, at: day(1))      // Tuesday
        daily.add(km: 80, at: day(8))
        daily.add(km: 60, at: day(15))
        daily.add(km: 5, at: day(2))        // Monday
        XCTAssertEqual(plan(tuesday).measured, [100, 80, 60])
        XCTAssertEqual(plan(tuesday).learnedKm, 80)
        XCTAssertEqual(plan(tuesday).plannedKm, 80)
    }

    func testDaysWithoutDrivingCountAsZero() {
        daily.add(km: 60, at: day(15))      // Tuesday three weeks ago; nothing since
        XCTAssertEqual(plan(tuesday).measured, [0, 0, 60])
        XCTAssertEqual(plan(monday).measured, [0, 0], "only Mondays after the first measurement")
    }

    func testTodayIsNotMeasuredYet() {
        daily.add(km: 30, at: day(7))       // last Wednesday
        daily.add(km: 12, at: now)
        XCTAssertEqual(plan(wednesday).measured, [30])
        XCTAssertEqual(daily.km(on: now), 12)
    }

    func testAtMostFiveMeasurementsPerDay() {
        for week in 0..<8 { daily.add(km: Double(10 + week), at: day(1 + 7 * week)) }
        XCTAssertEqual(plan(tuesday).measured, [10, 11, 12, 13, 14])
    }

    func testSeveralTripsOnOneDayAddUp() {
        daily.add(km: 12.5, at: day(1))
        daily.add(km: 7.5, at: day(1).addingTimeInterval(3 * 3600))
        XCTAssertEqual(plan(tuesday).measured, [20])
    }

    func testTooFewMeasurementsFallBackToSet() {
        daily.setSetKm(70, for: tuesday)
        daily.add(km: 100, at: day(1))
        daily.add(km: 80, at: day(8))
        XCTAssertNil(plan(tuesday).learnedKm)
        XCTAssertEqual(plan(tuesday).plannedKm, 70)
    }

    func testLearningCanBeSwitchedOff() {
        daily.setSetKm(70, for: tuesday)
        for week in 0..<3 { daily.add(km: 100, at: day(1 + 7 * week)) }
        XCTAssertEqual(plan(tuesday).plannedKm, 100)
        daily.learningEnabled = false
        XCTAssertEqual(plan(tuesday).plannedKm, 70)
        XCTAssertEqual(plan(tuesday).learnedKm, 100, "still shown")
    }

    func testSetDistancesAreStoredPerWeekday() {
        daily.setSetKm(130, for: monday)
        daily.setSetKm(-5, for: sunday)
        daily.setSetKm(99, for: 9)
        let again = DailyDistance(defaults: defaults, calendar: calendar)
        XCTAssertEqual(again.setKm(for: monday), 130)
        XCTAssertEqual(again.setKm(for: sunday), 0, "never negative")
        XCTAssertEqual(again.setKm(for: tuesday), DailyDistance.defaultSetKm)
    }

    // MARK: - Storage

    func testDistancesSurviveRestartAndCanBeCleared() {
        for week in 0..<3 { daily.add(km: 50, at: day(1 + 7 * week)) }
        let again = DailyDistance(defaults: defaults, calendar: calendar)
        XCTAssertEqual(again.plan(now: now).first { $0.weekday == tuesday }!.measured, [50, 50, 50])
        again.clear()
        XCTAssertTrue(DailyDistance(defaults: defaults, calendar: calendar).isEmpty)
    }

    func testOldDaysAreDropped() {
        daily.add(km: 50, at: day(200))
        daily.add(km: 50, at: day(1))
        XCTAssertEqual(daily.km(on: day(200)), 0)
        XCTAssertEqual(daily.km(on: day(1)), 50)
        XCTAssertLessThanOrEqual(plan(monday).measured.count, 5)
    }

    // MARK: - Charge advice

    func testNeededChargeIncludesReserve() {
        // 90 km × 300 Wh/km = 27 kWh of 90 kWh = 30 %, plus 10 % reserve.
        XCTAssertEqual(ChargeAdvice.neededSoc(km: 90, whPerKm: 300, capacityKWh: 90)!, 40, accuracy: 1e-9)
        XCTAssertEqual(ChargeAdvice.neededSoc(km: 0, whPerKm: 300, capacityKWh: 90)!, 10, accuracy: 1e-9)
    }

    func testNeededChargeIsAtMostFull() {
        XCTAssertEqual(ChargeAdvice.neededSoc(km: 500, whPerKm: 300, capacityKWh: 90), 100)
    }

    func testNoAdviceWithoutConsumptionOrCapacity() {
        XCTAssertNil(ChargeAdvice.neededSoc(km: 90, whPerKm: 0, capacityKWh: 90))
        XCTAssertNil(ChargeAdvice.neededSoc(km: 90, whPerKm: -50, capacityKWh: 90))
        XCTAssertNil(ChargeAdvice.neededSoc(km: 90, whPerKm: 300, capacityKWh: 0))
    }
}
