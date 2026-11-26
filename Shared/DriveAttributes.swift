import Foundation
import ActivityKit

/// The Live Activity while driving: shared by the app (which starts and updates it)
/// and the widget extension (which draws it on the lock screen, the Dynamic Island and CarPlay).
struct DriveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var soc: Double                 // %
        var rangeKm: Int?
        var whPerKm: Int?               // the average used for the range
        var powerKW: Double             // ABRP convention: positive = consumption
        var tripKm: Double
        var tempWarning: TemperatureWarning?

        enum TemperatureWarning: String, Codable, Hashable {
            case cold, hot
        }
    }

    /// The module the activity was started for.
    var moduleName: String
}
