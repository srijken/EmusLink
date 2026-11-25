import SwiftUI
import Charts

struct ConsumptionView: View {
    @EnvironmentObject var store: LiveStore
    @State private var confirmReset = false
    @State private var confirmClear = false

    var body: some View {
        let e = store.energy
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "Rit", value: fmt(e.tripWhPerKm, "%.0f"), unit: "Wh/km")
                        StatTile(title: "10 km", value: fmt(e.last10WhPerKm, "%.0f"), unit: "Wh/km")
                        StatTile(title: "100 km", value: fmt(e.last100WhPerKm, "%.0f"), unit: "Wh/km")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Verbruik per km (laatste \(e.perKm.count) km)")
                            .font(.headline)
                        if e.perKm.isEmpty {
                            Text("Nog geen gereden kilometers. Zet GPS aan in Instellingen en ga rijden.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else {
                            Chart {
                                ForEach(e.perKm) { p in
                                    BarMark(xStart: .value("van", -p.kmAgo - 0.9),
                                            xEnd: .value("tot", -p.kmAgo - 0.1),
                                            y: .value("Wh/km", p.whPerKm))
                                        .foregroundStyle(p.whPerKm < 0 ? Color.green : Color.orange)
                                }
                                if let avg = e.last10WhPerKm {
                                    RuleMark(y: .value("10 km", avg))
                                        .foregroundStyle(.white.opacity(0.6))
                                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                        .annotation(position: .top, alignment: .leading) {
                                            Text("10 km: \(Int(avg))").font(.caption2).foregroundStyle(.secondary)
                                        }
                                }
                            }
                            .chartXAxisLabel("km geleden")
                            .chartYAxisLabel("Wh/km")
                            .frame(height: 220)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))

                    VStack(spacing: 0) {
                        row("Ritafstand", String(format: "%.1f km", e.tripKm))
                        row("Energie deze rit", String(format: "%.2f kWh", e.tripWh / 1000))
                        row("In kWh/100 km (rit)", fmt(e.tripWhPerKm.map { $0 / 10 }, "%.1f"))
                        row("Rit gestart", e.tripStart?.formatted(date: .abbreviated, time: .shortened) ?? "–")
                        row("Historie bewaard", String(format: "%.0f km", e.historyKm))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))

                    HStack {
                        Button("Nieuwe rit starten", role: .destructive) { confirmReset = true }
                        Button("Historie wissen", role: .destructive) { confirmClear = true }
                    }
                    .buttonStyle(.bordered)

                    Text("Energie komt uit de BMS (spanning × stroom), afstand uit de GPS van de telefoon. Een nieuwe rit begint automatisch na 30 minuten stilstaan. Energie tijdens laden telt niet mee, en kilometers tellen alleen als de app met de module verbonden is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Verbruik")
            .confirmationDialog("Rit op nul zetten?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Nieuwe rit", role: .destructive) { AppModel.shared.resetTrip() }
            }
            .confirmationDialog("Alle verbruikshistorie wissen?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Wissen", role: .destructive) { AppModel.shared.clearHistory() }
            } message: {
                Text("De gemiddelden over 10 en 100 km en de grafiek beginnen dan opnieuw.")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}
