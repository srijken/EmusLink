import Foundation
import CoreLocation

/// The phone's GPS: for speed, consumption per km and the position in ABRP.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var _latest: CLLocation?

    /// On the main thread, for every new location.
    var onLocation: ((CLLocation) -> Void)?

    /// Safe from any thread.
    var latest: CLLocation? { lock.lock(); defer { lock.unlock() }; return _latest }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "locationEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "locationEnabled"); apply() }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        apply()
    }

    private func apply() {
        guard enabled else { manager.stopUpdatingLocation(); return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = false
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { apply() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            lock.lock(); _latest = loc; lock.unlock()
            onLocation?(loc)
        }
    }
}
