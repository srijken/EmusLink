import SwiftUI
import WidgetKit
import ActivityKit

@main
struct EmusLinkWidgets: WidgetBundle {
    var body: some Widget {
        DriveLiveActivity()
    }
}

/// The Live Activity while driving: battery, range and consumption.
/// `.small` is the size CarPlay and the Apple Watch use.
struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveAttributes.self) { context in
            ActivityFamilyView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BatteryLabel(state: s).font(.title2.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RangeLabel(state: s).font(.title2.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DetailsRow(state: s)
                }
            } compactLeading: {
                BatteryLabel(state: s)
            } compactTrailing: {
                RangeLabel(state: s)
            } minimal: {
                Text(verbatim: "\(Int(s.soc.rounded()))").foregroundStyle(socColor(s.soc))
            }
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

/// Picks the layout for the lock screen (`.medium`) or CarPlay and the Watch (`.small`).
private struct ActivityFamilyView: View {
    @Environment(\.activityFamily) private var family
    var state: DriveAttributes.ContentState
    var stale: Bool

    var body: some View {
        switch family {
        case .small: SmallView(state: state, stale: stale)
        default: LockScreenView(state: state, stale: stale)
        }
    }
}

private struct LockScreenView: View {
    var state: DriveAttributes.ContentState
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                BatteryLabel(state: state).font(.system(size: 34, weight: .bold, design: .rounded))
                Spacer()
                RangeLabel(state: state).font(.system(size: 28, weight: .semibold, design: .rounded))
            }
            ProgressView(value: min(max(state.soc, 0), 100), total: 100)
                .tint(socColor(state.soc))
            DetailsRow(state: state)
            if let warning = state.tempWarning {
                WarningLabel(warning: warning).font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .opacity(stale ? 0.5 : 1)
    }
}

/// CarPlay and the Apple Watch: little room, large numbers.
private struct SmallView: View {
    var state: DriveAttributes.ContentState
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                BatteryLabel(state: state).font(.title2.weight(.bold))
                Spacer(minLength: 4)
                RangeLabel(state: state).font(.title3.weight(.semibold))
            }
            if let warning = state.tempWarning {
                WarningLabel(warning: warning).font(.caption.weight(.semibold))
            } else if let w = state.whPerKm {
                Text(verbatim: "\(w) Wh/km").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .opacity(stale ? 0.5 : 1)
    }
}

private struct BatteryLabel: View {
    var state: DriveAttributes.ContentState
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "battery.75percent").foregroundStyle(socColor(state.soc))
            Text(verbatim: String(format: "%.0f %%", state.soc)).monospacedDigit()
        }
    }
}

private struct RangeLabel: View {
    var state: DriveAttributes.ContentState
    var body: some View {
        Text(verbatim: state.rangeKm.map { "\($0) km" } ?? "– km").monospacedDigit()
    }
}

private struct DetailsRow: View {
    var state: DriveAttributes.ContentState
    var body: some View {
        HStack {
            Text(verbatim: state.whPerKm.map { "\($0) Wh/km" } ?? "– Wh/km")
            Spacer()
            Text(verbatim: String(format: "%.1f kW", state.powerKW))
                .foregroundStyle(state.powerKW < 0 ? .green : .primary)
            Spacer()
            Text(verbatim: String(format: "%.1f km", state.tripKm))
        }
        .font(.subheadline).monospacedDigit()
    }
}

private struct WarningLabel: View {
    var warning: DriveAttributes.ContentState.TemperatureWarning
    var body: some View {
        switch warning {
        case .hot: Label("Battery hot", systemImage: "thermometer.high").foregroundStyle(.red)
        case .cold: Label("Battery cold", systemImage: "thermometer.snowflake").foregroundStyle(.cyan)
        }
    }
}

private func socColor(_ soc: Double) -> Color {
    soc < 15 ? .red : soc < 30 ? .orange : .green
}
