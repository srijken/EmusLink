import SwiftUI
import Charts

/// The battery over weeks and months: state of health and how far the cells are apart.
struct BatteryHealthCard: View {
    var summary: HealthSummary

    private var sohPoints: [HealthPoint] { summary.points.filter { $0.soh != nil } }
    private var spreadPoints: [HealthPoint] { summary.points.filter { $0.restSpreadMv != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery health").font(.headline)

            if summary.points.isEmpty {
                Text("Nothing measured yet. One value per day is kept; the charts fill up as you drive.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                soh
                Divider()
                spread
            }

            Text("SoH is the BMS's own estimate of the remaining capacity. Cell spread is the difference between the lowest and the highest cell while hardly any current flows; under load it is always larger. The BMS reports cells in steps of 10 mV. A spread that keeps growing points to a cell that ages faster or a pack that needs balancing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }

    // MARK: - State of health

    @ViewBuilder private var soh: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("State of health").foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: summary.latestSoh.map { String(format: "%.1f %%", $0) } ?? "–")
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }
            if let change = summary.sohChange {
                Text("\(String(format: "%+.1f", change)) percentage points in \(summary.sohDays) days")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if sohPoints.count >= 2 {
                Chart(sohPoints) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("SoH", p.soh ?? 0))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.green)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .chartYAxisLabel { Text(verbatim: "%") }
                .frame(height: 140)
            }
        }
        .font(.subheadline)
    }

    // MARK: - Cell spread

    @ViewBuilder private var spread: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cell spread at rest").foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: summary.recentSpreadMv.map { String(format: "%.0f mV", $0) } ?? "–")
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }
            HStack {
                Text("Average of the last 7 days").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                levelLabel
            }
            if let earlier = summary.earlierSpreadMv {
                HStack {
                    Text("The 30 days before").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: "%.0f mV", earlier)).font(.footnote).monospacedDigit()
                }
            }
            if summary.spreadGrowing {
                Label("The spread is growing", systemImage: "arrow.up.right")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if spreadPoints.count >= 2 {
                Chart {
                    ForEach(spreadPoints) { p in
                        BarMark(x: .value("Day", p.date, unit: .day), y: .value("mV", p.restSpreadMv ?? 0))
                            .foregroundStyle(color(BatteryHealth.level(p.restSpreadMv)))
                    }
                    RuleMark(y: .value("mV", BatteryHealth.watchMv))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .chartYAxisLabel { Text(verbatim: "mV") }
                .frame(height: 140)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var levelLabel: some View {
        switch summary.level {
        case .unknown: Text(verbatim: "–").foregroundStyle(.secondary)
        case .good: Text("Good").foregroundStyle(.green)
        case .watch: Text("Keep an eye on it").foregroundStyle(.yellow)
        case .high: Text("High").foregroundStyle(.red)
        }
    }

    private func color(_ level: SpreadLevel) -> Color {
        switch level {
        case .unknown, .good: .green
        case .watch: .yellow
        case .high: .red
        }
    }
}
