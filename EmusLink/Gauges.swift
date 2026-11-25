import SwiftUI

/// Boogmeter van 270°. Vult vanaf `zero`, dus kan ook naar beneden uitslaan (regen).
struct ArcGauge: View {
    var value: Double?
    var range: ClosedRange<Double>
    var zero: Double = 0
    var lineWidth: CGFloat = 14
    var positive: Color = .orange
    var negative: Color = .green
    var gradient: Gradient? = nil

    private func frac(_ x: Double) -> Double {
        let f = (x - range.lowerBound) / (range.upperBound - range.lowerBound)
        return min(max(f, 0), 1)
    }

    var body: some View {
        let z = frac(max(min(zero, range.upperBound), range.lowerBound))
        let v = frac(value ?? zero)
        let from = min(z, v), to = max(z, v)
        let color = (value ?? zero) >= zero ? positive : negative
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Group {
                if let gradient {
                    Circle()
                        .trim(from: from * 0.75, to: max(to * 0.75, from * 0.75 + 0.001))
                        .stroke(AngularGradient(gradient: gradient, center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(270)),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                } else {
                    Circle()
                        .trim(from: from * 0.75, to: max(to * 0.75, from * 0.75 + 0.001))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(135))
            .animation(.easeOut(duration: 0.4), value: v)

        }
    }
}

/// Meter met grote waarde in het midden.
struct GaugeCard: View {
    var title: String
    var value: Double?
    var format: String
    var unit: String
    var range: ClosedRange<Double>
    var zero: Double = 0
    var positive: Color = .orange
    var negative: Color = .green

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ArcGauge(value: value, range: range, zero: zero, lineWidth: 12,
                         positive: positive, negative: negative)
                VStack(spacing: 0) {
                    Text(value.map { String(format: format, $0) } ?? "–")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
            }
            .frame(height: 140)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.06)))
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var unit: String = ""
    var detail: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !unit.isEmpty { Text(unit).font(.footnote).foregroundStyle(.secondary) }
            }
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }
}

func fmt(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "–" }
