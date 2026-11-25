import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: LiveStore

    private var socGradient: Gradient {
        Gradient(colors: [.red, .orange, .yellow, .green, .green])
    }

    var body: some View {
        let s = store.snapshot
        let e = store.energy
        ScrollView {
            VStack(spacing: 14) {
                statusBar

                // Battery
                ZStack {
                    ArcGauge(value: s.soc, range: 0...100, zero: 0, lineWidth: 22, gradient: socGradient)
                    VStack(spacing: 2) {
                        Text(fmt(s.soc, "%.1f"))
                            .font(.system(size: 72, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("% battery").font(.headline).foregroundStyle(.secondary)
                        if let r = store.rangeKm {
                            Text(verbatim: "≈ \(Int(r)) km").font(.title2.weight(.semibold)).padding(.top, 6)
                        } else {
                            Text("range: no consumption yet").font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                }
                .frame(height: 280)
                .padding(.horizontal, 30)

                // Consumption & speed
                HStack(spacing: 12) {
                    GaugeCard(title: "Consumption", value: e.instantWhPerKm, format: "%.0f", unit: "Wh/km",
                              range: -300...600, zero: 0, positive: .orange, negative: .green)
                    GaugeCard(title: "Speed", value: store.speedKmh, format: "%.0f", unit: "km/h",
                              range: 0...140, zero: 0, positive: .blue, negative: .blue)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatTile(title: "Power", value: fmt(s.powerKW, "%.1f"), unit: "kW",
                             tint: (s.powerKW ?? 0) < 0 ? .green : .primary)
                    StatTile(title: "Trip average", value: fmt(e.tripWhPerKm, "%.0f"), unit: "Wh/km",
                             detail: String(format: "%.1f km · %.2f kWh", e.tripKm, e.tripWh / 1000))
                    StatTile(title: "Last 10 km", value: fmt(e.last10WhPerKm, "%.0f"), unit: "Wh/km")
                    StatTile(title: "Last 100 km", value: fmt(e.last100WhPerKm, "%.0f"), unit: "Wh/km")
                    StatTile(title: "Voltage", value: fmt(s.packVoltage, "%.1f"), unit: "V",
                             detail: s.current.map { String(format: "%.1f A", $0) })
                    StatTile(title: "Battery temperature", value: fmt(s.tempAvg, "%.0f"), unit: "°C",
                             detail: (s.tempMin != nil && s.tempMax != nil)
                                ? String(format: "min %.0f · max %.0f", s.tempMin!, s.tempMax!) : nil,
                             tint: (s.tempMin ?? 10) <= 0 ? .cyan : .primary)
                    StatTile(title: "Cells", value: fmt(s.cellAvg, "%.2f"), unit: "V",
                             detail: (s.cellMin != nil && s.cellMax != nil)
                                ? String(format: "%.2f – %.2f V (Δ %.0f mV)", s.cellMin!, s.cellMax!,
                                         (s.cellMax! - s.cellMin!) * 1000) : nil)
                    StatTile(title: "Remaining", value: fmt(store.remainingKWh, "%.1f"), unit: "kWh",
                             detail: s.soh.map { String(format: "SoH %.0f %%", $0) })
                }
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(store.connection == .connected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(verbatim: store.connection == .connected ? (store.deviceName ?? store.connection.label) : store.connection.label)
                .font(.subheadline)
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(store.abrpOK ? .green : .secondary)
            Text(verbatim: store.abrpLastSent.map { "ABRP \($0.formatted(date: .omitted, time: .shortened))" } ?? "ABRP –")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
