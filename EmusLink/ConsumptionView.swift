import SwiftUI
import Charts

struct ConsumptionView: View {
    @EnvironmentObject var store: LiveStore
    @AppStorage("chartRangeKm") private var rangeKm = 10
    @State private var confirmReset = false
    @State private var confirmClear = false

    private static let ranges = [10, 25, 50]

    /// Shorter ranges get a finer line.
    private var bucketKm: Double { rangeKm <= 10 ? 0.2 : rangeKm <= 25 ? 0.5 : 1.0 }

    var body: some View {
        let e = store.energy
        let points = EnergyTracker.curve(segments: e.recent, rangeKm: Double(rangeKm), bucketKm: bucketKm)
        let average = EnergyTracker.average(segments: e.recent, rangeKm: Double(rangeKm))
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "Trip", value: fmt(e.tripWhPerKm, "%.0f"), unit: "Wh/km")
                        StatTile(title: "10 km", value: fmt(e.last10WhPerKm, "%.0f"), unit: "Wh/km")
                        StatTile(title: "100 km", value: fmt(e.last100WhPerKm, "%.0f"), unit: "Wh/km")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Consumption").font(.headline)
                            Spacer()
                            Picker("Distance", selection: $rangeKm) {
                                ForEach(Self.ranges, id: \.self) { Text(verbatim: "\($0) km").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 210)
                        }

                        if points.count < 2 {
                            Text("Not enough kilometres driven yet. Turn on GPS in Settings and start driving.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 220)
                        } else {
                            ConsumptionChart(points: points, rangeKm: Double(rangeKm),
                                             average: average, typical: e.last100WhPerKm)
                                .frame(height: 240)
                        }

                        HStack(alignment: .firstTextBaseline) {
                            summary("Average", value: fmt(average, "%.0f"), unit: "Wh/km")
                            Spacer()
                            summary("Projected range", value: fmt(projectedRange(average), "%.0f"), unit: "km",
                                    alignment: .trailing)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))

                    VStack(spacing: 0) {
                        row("Trip distance", String(format: "%.1f km", e.tripKm))
                        row("Energy this trip", String(format: "%.2f kWh", e.tripWh / 1000))
                        row("In kWh/100 km (trip)", fmt(e.tripWhPerKm.map { $0 / 10 }, "%.1f"))
                        row("Trip started", e.tripStart?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                        row("History kept", String(format: "%.0f km", e.historyKm))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))

                    HStack {
                        Button("Start new trip", role: .destructive) { confirmReset = true }
                        Button("Clear history", role: .destructive) { confirmClear = true }
                    }
                    .buttonStyle(.bordered)

                    Text("Energy comes from the BMS (voltage × current), distance from the phone's GPS. A new trip starts automatically after 30 minutes of standing still. Energy while charging is not counted, and kilometres only count while the app is connected to the module.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Consumption")
            .confirmationDialog("Reset the trip?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("New trip", role: .destructive) { AppModel.shared.resetTrip() }
            }
            .confirmationDialog("Clear all consumption history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { AppModel.shared.clearHistory() }
            } message: {
                Text("The 10 km and 100 km averages and the chart will start over.")
            }
        }
    }

    /// Range if the rest of the battery is used at the average of the chosen distance.
    private func projectedRange(_ whPerKm: Double?) -> Double? {
        guard let kwh = store.remainingKWh, let whPerKm, whPerKm > 50 else { return nil }
        return kwh * 1000 / whPerKm
    }

    private func summary(_ label: LocalizedStringKey, value: String, unit: String,
                         alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}

/// Consumption over distance as a filled line: consumption above zero, regeneration (green) below.
/// The most recent kilometre is on the right. A dashed line marks the average over the range,
/// a solid thin line the long-term (100 km) average.
struct ConsumptionChart: View {
    var points: [ConsumptionPoint]
    var rangeKm: Double
    var average: Double?
    var typical: Double?

    private let use = Color.orange
    private let regen = Color.green

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("km ago", -p.kmAgo), y: .value("Wh/km", max(p.whPerKm, 0)),
                         series: .value("Part", "use"), stacking: .unstacked)
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [use.opacity(0.55), use.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                AreaMark(x: .value("km ago", -p.kmAgo), y: .value("Wh/km", min(p.whPerKm, 0)),
                         series: .value("Part", "regen"), stacking: .unstacked)
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [regen.opacity(0.05), regen.opacity(0.55)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("km ago", -p.kmAgo), y: .value("Wh/km", p.whPerKm))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.white)
            }
            RuleMark(y: .value("Wh/km", 0))
                .foregroundStyle(.white.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
            if let typical {
                RuleMark(y: .value("Wh/km", typical))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .bottom, alignment: .leading, spacing: 2) {
                        Text(verbatim: "100 km").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let average {
                RuleMark(y: .value("Wh/km", average))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Average").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: -rangeKm...0)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .stride(by: rangeKm / 5)) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let km = value.as(Double.self) { Text(verbatim: "\(Int(abs(km).rounded()))") }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel()
            }
        }
        .chartXAxisLabel("km ago")
        .chartYAxisLabel("Wh/km")
        .chartLegend(.hidden)
    }
}
