import Foundation
import UserNotifications

/// Local notifications (also shown on CarPlay once the user allows that).
enum AlertNotifier {
    static let temperatureCategory = "temperature"

    /// At launch: ask for permission and show notifications while the app is open too.
    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundPresenter.shared
        center.setNotificationCategories([
            UNNotificationCategory(identifier: temperatureCategory, actions: [], intentIdentifiers: [],
                                   options: [.allowInCarPlay]),
        ])
        center.requestAuthorization(options: [.alert, .sound, .carPlay]) { _, _ in }
    }

    /// The text of a temperature warning; nil when the temperature is back to normal.
    static func temperatureText(_ state: TemperatureState, tempMin: Double, tempMax: Double,
                                low: Double, high: Double) -> (title: String, body: String)? {
        switch state {
        case .normal:
            return nil
        case .hot:
            return (String(localized: "Battery hot"),
                    String(localized: "Highest battery temperature \(Int(tempMax.rounded())) °C (limit \(Int(high.rounded())) °C)."))
        case .cold:
            return (String(localized: "Battery cold"),
                    String(localized: "Lowest battery temperature \(Int(tempMin.rounded())) °C (limit \(Int(low.rounded())) °C): less power and regeneration."))
        }
    }

    static func temperature(_ state: TemperatureState, tempMin: Double, tempMax: Double, low: Double, high: Double) {
        guard let text = temperatureText(state, tempMin: tempMin, tempMax: tempMax, low: low, high: high) else { return }
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.categoryIdentifier = temperatureCategory
        // The same identifier replaces an earlier temperature warning instead of piling them up.
        let request = UNNotificationRequest(identifier: "temperature", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Without a delegate iOS does not show notifications while the app is in the foreground.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
