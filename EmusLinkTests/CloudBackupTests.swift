import XCTest
@testable import EmusLink

private final class FakeCloud: KeyValueStore {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func synchronize() -> Bool { true }
}

final class CloudBackupTests: XCTestCase {
    private var suite = ""
    private var local: UserDefaults!
    private var cloud: FakeCloud!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "EmusLinkTests.\(UUID().uuidString)"
        local = UserDefaults(suiteName: suite)
        cloud = FakeCloud()
    }

    override func tearDown() {
        local.removePersistentDomain(forName: suite)
    }

    func testRestoresABackupAtLaunch() {
        cloud.values["learnFromTrips"] = false
        cloud.values["dailyDistance.v1"] = Data([1, 2, 3])
        local.set(true, forKey: "learnFromTrips")                  // written since the install
        let backup = CloudBackup(local: local, cloud: cloud)
        XCTAssertEqual(Set(backup.restoreIfNeeded(now: now)), ["learnFromTrips", "dailyDistance.v1"])
        XCTAssertEqual(local.object(forKey: "learnFromTrips") as? Bool, false, "the backup wins")
        XCTAssertEqual(local.data(forKey: "dailyDistance.v1"), Data([1, 2, 3]))
        XCTAssertTrue(backup.isReady)
        XCTAssertTrue(backup.restoreIfNeeded(now: now).isEmpty, "only once")
    }

    func testDoesNotOverwriteABackupThatMayStillArrive() {
        local.set(Data([9]), forKey: "speedProfile.v1")
        let backup = CloudBackup(local: local, cloud: cloud)
        backup.restoreIfNeeded(now: now)
        XCTAssertFalse(backup.backUp(now: now.addingTimeInterval(60)))
        XCTAssertNil(cloud.values["speedProfile.v1"])

        cloud.values["speedProfile.v1"] = Data([7])                // arrives late
        XCTAssertEqual(backup.cloudChanged(), ["speedProfile.v1"])
        XCTAssertEqual(local.data(forKey: "speedProfile.v1"), Data([7]))
        XCTAssertTrue(backup.backUp(now: now.addingTimeInterval(120)))
    }

    func testStartsBackingUpWhenNoBackupArrives() {
        local.set(Data([9]), forKey: "speedProfile.v1")
        local.set(Data([5]), forKey: "abrpQueue.v1")
        local.set("x", forKey: "peripheralID")
        let backup = CloudBackup(local: local, cloud: cloud)
        backup.restoreIfNeeded(now: now)
        XCTAssertTrue(backup.backUp(now: now.addingTimeInterval(CloudBackup.waitForBackup)))
        XCTAssertEqual(cloud.values["speedProfile.v1"] as? Data, Data([9]))
        XCTAssertNil(cloud.values["abrpQueue.v1"], "the queue is not backed up")
        XCTAssertNil(cloud.values["peripheralID"], "differs per iPhone")
        XCTAssertEqual(backup.lastBackup, now.addingTimeInterval(CloudBackup.waitForBackup))
        XCTAssertTrue(backup.cloudChanged().isEmpty, "once ready, iCloud no longer overwrites local data")
    }

    func testBackupMirrorsRemovalsAndSkipsHugeValues() {
        local.set(true, forKey: "cloudBackup.ready")
        cloud.values["batteryHealth.v1"] = Data([1])
        local.set(Data(count: CloudBackup.maxValueBytes + 1), forKey: "energyState.v1")
        let backup = CloudBackup(local: local, cloud: cloud)
        XCTAssertTrue(backup.backUp(now: now))
        XCTAssertNil(cloud.values["batteryHealth.v1"], "cleared locally, so cleared in the backup")
        XCTAssertNil(cloud.values["energyState.v1"])
    }

    func testReloadReadsTheRestoredState() {
        let daily = DailyDistance(defaults: local)
        XCTAssertTrue(daily.isEmpty)
        let other = DailyDistance(defaults: local)
        other.add(km: 12, at: now)
        other.add(km: 0.5, at: now)                                // saved from 0.2 km
        daily.reload()
        XCTAssertFalse(daily.isEmpty)
    }
}
