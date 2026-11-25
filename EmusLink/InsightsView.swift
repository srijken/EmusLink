import SwiftUI
import Charts

/// What the app has learned from driving: the most efficient speed and the usual distance per weekday.
struct InsightsView: View {
    @EnvironmentObject var store: LiveStore
    @State private var learning = true
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    EfficientSpeedCard(summary: store.speedProfile)
                    tripsCard
                    Button("Clear measurements", role: .destructive) { confirmClear = true }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Insights")
            .confirmationDialog("Clear the speed and daily measurements?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { AppModel.shared.clearInsights() }
            }
        }
        .onAppear { learning = AppModel.shared.daily.learningEnabled }
    }

    // MARK: - Learning from trips

    private var calendar: Calendar { AppModel.shared.daily.calendar }

    private func dayName(_ weekday: Int) -> String {
        calendar.shortStandaloneWeekdaySymbols[weekday - 1].capitalized
    }

    private var tripsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $learning) { Text("Learn from trips").font(.headline) }
                .onChange(of: learning) { _, on in AppModel.shared.setLearning(on) }

            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Day").gridColumnAlignment(.leading)
                    Text("Set")
                    Text("Learned")
                    Text("Measured").gridColumnAlignment(.leading)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(store.week) { day in
                    GridRow {
                        Text(verbatim: dayName(day.weekday))
                        Text(verbatim: km(day.setKm))
                            .foregroundStyle(learning && day.learnedKm != nil ? .secondary : .primary)
                        Text(verbatim: day.learnedKm.map(km) ?? "–")
                            .foregroundStyle(learning ? .primary : .secondary)
                        Text(verbatim: day.measured.isEmpty ? "–" : day.measured.map { String(format: "%.0f", $0) }
                            .joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .monospacedDigit()
                }
            }
            .font(.subheadline)

            NavigationLink("Change set distances") { SetDistancesView() }
                .font(.subheadline)

            Divider()
            tomorrow

            Text("Learned counts from 3 measurements per day; until then the set distance applies. It is a cautious usual day: the distance that covers about three out of four of the last days. The app cannot control charging; this is advice only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private var tomorrow: some View {
        let date = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let weekday = calendar.component(.weekday, from: date)
        if let day = store.week.first(where: { $0.weekday == weekday }) {
            let needed = needed(for: day.plannedKm)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tomorrow (\(dayName(weekday))): about \(Int(day.plannedKm.rounded())) km")
                    .font(.subheadline.weight(.semibold))
                infoRow("Needed, including reserve", needed.map { String(format: "%.0f %%", $0) } ?? "–")
                infoRow("In the battery now", store.snapshot.soc.map { String(format: "%.0f %%", $0) } ?? "–")
                infoRow("Driven today", km(store.todayKm))
                if let needed, let soc = store.snapshot.soc {
                    if soc >= needed {
                        Label("Enough charge for tomorrow", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Charge to at least \(Int(needed.rounded(.up))) %", systemImage: "bolt.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    private func needed(for km: Double) -> Double? {
        guard let whPerKm = store.planningWhPerKm, let capacity = store.capacityKWh else { return nil }
        return ChargeAdvice.neededSoc(km: km, whPerKm: whPerKm, capacityKWh: capacity)
    }

    private func km(_ value: Double) -> String { String(format: "%.0f km", value) }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).monospacedDigit()
        }
    }
}

/// At which speed does the car use the least per km?
struct EfficientSpeedCard: View {
    var summary: SpeedSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Most efficient speed").font(.headline)
            Text("At which speed does the car use the least per km?")
                .font(.footnote).foregroundStyle(.secondary)

            if let best = summary.best, let lowest = summary.lowestWhPerKm {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: "\(Int(best.lowerBound))–\(Int(best.upperBound))")
                        .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(verbatim: "km/h").font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    row("Lowest", String(format: "%.0f Wh/km", lowest))
                    ForEach([100, 130], id: \.self) { speed in
                        if let value = summary.whPerKm(at: Double(speed)), lowest > 0 {
                            row("At \(speed) km/h",
                                String(format: "%.0f Wh/km  %+.0f %%", value, (value / lowest - 1) * 100))
                        }
                    }
                    if let regen = summary.regenShare {
                        row("Recovered while braking", String(format: "%.0f %%", regen * 100))
                    }
                    row("Measured", String(format: "%.0f km", summary.totalKm))
                }
                .font(.subheadline)
            }

            if summary.points.count < 2 {
                Text("Not enough driving measured yet. The curve appears after a few kilometres at different speeds.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    if let best = summary.best {
                        RectangleMark(xStart: .value("Speed", best.lowerBound), xEnd: .value("Speed", best.upperBound))
                            .foregroundStyle(.white.opacity(0.10))
                    }
                    ForEach(summary.points) { p in
                        LineMark(x: .value("Speed", p.speedKmh), y: .value("Wh/km", p.whPerKm))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .foregroundStyle(.orange)
                        PointMark(x: .value("Speed", p.speedKmh), y: .value("Wh/km", p.whPerKm))
                            .symbolSize(p.km >= SpeedProfile.wellMeasuredKm ? 60 : 16)
                            .foregroundStyle(.orange)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: 20)) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .chartXAxisLabel { Text(verbatim: "km/h") }
                .chartYAxisLabel { Text(verbatim: "Wh/km") }
                .frame(height: 220)
            }

            Text("Measured while driving, per speed band of 10 km/h, including accelerating, regeneration and heating. The large number is the range of speeds where consumption is at most 6 % above the lowest; lowest is the best band of 20 km/h. Small points have little data (under 20 km). Everything is higher in winter.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).monospacedDigit()
        }
    }
}

/// The distance the driver expects per day of the week.
struct SetDistancesView: View {
    @EnvironmentObject var store: LiveStore

    var body: some View {
        let calendar = AppModel.shared.daily.calendar
        Form {
            Section {
                ForEach(store.week) { day in
                    Stepper(value: Binding(get: { day.setKm },
                                           set: { AppModel.shared.setSetKm($0, for: day.weekday) }),
                            in: 0...500, step: 10) {
                        HStack {
                            Text(verbatim: calendar.standaloneWeekdaySymbols[day.weekday - 1].capitalized)
                            Spacer()
                            Text(verbatim: String(format: "%.0f km", day.setKm))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Used until the app has learned a day from at least 3 measurements, or when learning is off.")
            }
        }
        .navigationTitle("Set distances")
    }
}
