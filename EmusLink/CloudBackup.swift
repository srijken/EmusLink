import Foundation

/// The part of `NSUbiquitousKeyValueStore` the backup uses, so tests can use a dictionary instead.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStore {}

/// Keeps a copy of the learned data and the settings in iCloud (key-value storage, at most 1 MB),
/// so they survive a reinstall or a new iPhone. There is one car and one iPhone: this is a backup,
/// not a merge between devices.
///
/// After a fresh install iCloud may need a moment to download the backup while the app already
/// measures. Until a backup has been restored, or none turned out to exist, nothing is written to
/// iCloud, so a fresh install does not overwrite the backup. Thread-safe.
final class CloudBackup {
    /// What is backed up. Not the module's identifier (it differs per iPhone) and not the ABRP queue.
    static let keys = [
        "energyState.v1", "speedProfile.v1", "dailyDistance.v1", "batteryHealth.v1",
        "setKmPerWeekday", "learnFromTrips",
        "abrpApiKey", "abrpToken", "abrpEnabled",
        "tempAlert.enabled", "tempAlert.low", "tempAlert.high",
        "nameFilter", "pollingEnabled", "locationEnabled",
    ]
    /// Values above this size are skipped, so the store stays well within its 1 MB.
    static let maxValueBytes = 300_000
    /// How long to wait for a backup to arrive before assuming there is none (seconds the app runs).
    static let waitForBackup: TimeInterval = 600

    private static let readyKey = "cloudBackup.ready"
    private static let lastBackupKey = "cloudBackup.lastBackup"

    private let lock = NSLock()
    private let local: UserDefaults
    private let cloud: KeyValueStore
    private var waitingSince: Date?

    init(local: UserDefaults = .standard, cloud: KeyValueStore = NSUbiquitousKeyValueStore.default) {
        self.local = local
        self.cloud = cloud
    }

    /// True once local data may be written to iCloud.
    var isReady: Bool { local.bool(forKey: Self.readyKey) }

    var lastBackup: Date? { local.object(forKey: Self.lastBackupKey) as? Date }

    /// At launch, before anything reads its data. Returns the keys that were restored.
    @discardableResult
    func restoreIfNeeded(now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !isReady else { return [] }
        cloud.synchronize()
        let restored = restoreLocked()
        if restored.isEmpty, waitingSince == nil { waitingSince = now }
        return restored
    }

    /// When iCloud reports new data from the server. Returns the keys that were restored;
    /// the caller must then reload what it keeps in memory.
    @discardableResult
    func cloudChanged() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !isReady else { return [] }
        return restoreLocked()
    }

    /// Copies the local values to iCloud, unless a backup may still be on its way.
    /// Returns whether it was written.
    @discardableResult
    func backUp(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !isReady {
            guard let since = waitingSince, now.timeIntervalSince(since) >= Self.waitForBackup else { return false }
            local.set(true, forKey: Self.readyKey)          // no backup arrived: this is the first one
        }
        for key in Self.keys {
            guard let value = local.object(forKey: key) else { cloud.removeObject(forKey: key); continue }
            if let data = value as? Data, data.count > Self.maxValueBytes { continue }
            cloud.set(value, forKey: key)
        }
        local.set(now, forKey: Self.lastBackupKey)
        cloud.synchronize()
        return true
    }

    // MARK: - Internal (lock held)

    /// The backup wins over what was measured since the install: that is at most a few minutes.
    private func restoreLocked() -> [String] {
        let present = Self.keys.filter { cloud.object(forKey: $0) != nil }
        guard !present.isEmpty else { return [] }
        for key in present { local.set(cloud.object(forKey: key), forKey: key) }
        local.set(true, forKey: Self.readyKey)
        waitingSince = nil
        return present
    }
}
