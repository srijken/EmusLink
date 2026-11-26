import Foundation
import ActivityKit
import UIKit

/// Starts, updates and ends the Live Activity while the car is on.
/// iOS only lets an app start a Live Activity while it is in the foreground (the app on screen,
/// or its CarPlay screen); after that it can be updated from the background. Main thread only.
final class LiveActivityController {
    /// Updates more often than this are throttled by iOS anyway.
    static let updateInterval: TimeInterval = 10
    /// Without the module for this long, the car counts as off and the activity ends.
    static let endAfterDisconnect: TimeInterval = 120

    private let defaults: UserDefaults
    private var activity: Activity<DriveAttributes>?
    private var lastState: DriveAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private var disconnectedSince: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // An activity from an earlier run of the app (for example after iOS stopped it).
        activity = Activity<DriveAttributes>.activities.first
    }

    var enabled: Bool {
        get { defaults.object(forKey: "liveActivity.enabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "liveActivity.enabled")
            if !newValue { end() }
        }
    }

    var isRunning: Bool { activity != nil }

    /// The content of the activity, from what the dashboard shows.
    static func state(snapshot: BMSSnapshot, rangeKm: Double?, whPerKm: Double?, tripKm: Double,
                      temperature: TemperatureState) -> DriveAttributes.ContentState? {
        guard let soc = snapshot.soc else { return nil }
        let warning: DriveAttributes.ContentState.TemperatureWarning? =
            switch temperature {
            case .normal: nil
            case .cold: .cold
            case .hot: .hot
            }
        return DriveAttributes.ContentState(
            soc: (soc * 10).rounded() / 10,
            rangeKm: rangeKm.map { Int($0.rounded()) },
            whPerKm: whPerKm.map { Int($0.rounded()) },
            powerKW: ((snapshot.powerKW ?? 0) * 10).rounded() / 10,
            tripKm: (tripKm * 10).rounded() / 10,
            tempWarning: warning)
    }

    /// An unchanged state is sent again after this long, so the activity is not marked as outdated.
    static let refreshInterval: TimeInterval = 120

    /// Whether a new state is worth an update: always for a warning, else at most every `updateInterval`.
    static func shouldUpdate(from old: DriveAttributes.ContentState?, to new: DriveAttributes.ContentState,
                             since: TimeInterval) -> Bool {
        guard let old else { return true }
        if old == new { return since >= refreshInterval }
        if old.tempWarning != new.tempWarning { return true }
        return since >= updateInterval
    }

    /// Called about once per second with what the screens show.
    func tick(store: LiveStore, now: Date = Date()) {
        guard enabled else { return }
        guard store.connection == .connected else {
            if disconnectedSince == nil { disconnectedSince = now }
            if let since = disconnectedSince, now.timeIntervalSince(since) >= Self.endAfterDisconnect { end() }
            return
        }
        disconnectedSince = nil
        guard let state = Self.state(snapshot: store.snapshot, rangeKm: store.rangeKm,
                                     whPerKm: store.planningWhPerKm, tripKm: store.energy.tripKm,
                                     temperature: store.temperatureState) else { return }

        if activity == nil {
            start(state, name: store.deviceName ?? "EmusLink")
        } else if Self.shouldUpdate(from: lastState, to: state, since: now.timeIntervalSince(lastUpdate)) {
            update(state, now: now)
        }
    }

    private func start(_ state: DriveAttributes.ContentState, name: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        do {
            activity = try Activity.request(attributes: DriveAttributes(moduleName: name),
                                            content: content(state), pushType: nil)
            lastState = state
            lastUpdate = Date()
        } catch {
            AppModel.shared.store.addLog(String(localized: "Live Activity not started: \(error.localizedDescription)"))
        }
    }

    private func update(_ state: DriveAttributes.ContentState, now: Date) {
        guard let activity else { return }
        lastState = state
        lastUpdate = now
        let content = content(state)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func content(_ state: DriveAttributes.ContentState) -> ActivityContent<DriveAttributes.ContentState> {
        // Marked as outdated when no update came for a few minutes (app stopped, phone out of the car).
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
    }
}
