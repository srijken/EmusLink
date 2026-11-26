import UIKit
import CarPlay

/// CarPlay ("Driving Task" category): four tiles with gauges rendered as images.
/// This type of app may only use Apple's templates; free drawing is only for navigation apps.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var grid: CPGridTemplate?
    private var timer: Timer?
    private var shownTemperature: TemperatureState = .normal

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let grid = CPGridTemplate(title: "EmusLink", gridButtons: makeButtons())
        self.grid = grid
        interfaceController.setRootTemplate(grid, animated: false, completion: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let grid = self.grid else { return }
            grid.updateGridButtons(self.makeButtons())
            self.checkTemperature()
        }
    }

    /// Shows an alert once each time the battery becomes too hot or too cold.
    private func checkTemperature() {
        let store = AppModel.shared.store
        let state = store.temperatureState
        guard state != shownTemperature else { return }
        shownTemperature = state
        let s = store.snapshot, monitor = AppModel.shared.temperature
        guard let interfaceController, interfaceController.presentedTemplate == nil,
              let lo = s.tempMin, let hi = s.tempMax,
              let text = AlertNotifier.temperatureText(state, tempMin: lo, tempMax: hi,
                                                       low: monitor.lowLimit, high: monitor.highLimit)
        else { return }
        let ok = CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [text.body, text.title], actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        timer?.invalidate()
        timer = nil
        grid = nil
        self.interfaceController = nil
    }

    private func makeButtons() -> [CPGridButton] {
        let store = AppModel.shared.store
        let e = store.energy
        let consumption = e.instantWhPerKm ?? e.last10WhPerKm

        let buttons: [(String, UIImage)] = [
            (String(localized: "Consumption"), GaugeImage.render(value: consumption, range: -300...600, zero: 0,
                                           text: fmt(consumption, "%.0f"), unit: "Wh/km",
                                           positive: .systemOrange, negative: .systemGreen)),
            (String(localized: "Speed"), GaugeImage.render(value: store.speedKmh, range: 0...140, zero: 0,
                                           text: String(format: "%.0f", store.speedKmh), unit: "km/h",
                                           positive: .systemBlue, negative: .systemBlue)),
            (String(localized: "Battery"), GaugeImage.render(value: store.snapshot.soc, range: 0...100, zero: 0,
                                       text: fmt(store.snapshot.soc, "%.0f"), unit: "%",
                                       positive: socColor(store.snapshot.soc), negative: .systemRed)),
            (String(localized: "Range"), GaugeImage.render(value: store.rangeKm, range: 0...300, zero: 0,
                                        text: store.rangeKm.map { "\(Int($0))" } ?? "–", unit: "km",
                                        positive: .systemTeal, negative: .systemTeal)),
        ]
        return buttons.map { title, image in
            CPGridButton(titleVariants: [title], image: image) { [weak self] _ in self?.showDetails() }
        }
    }

    private func socColor(_ soc: Double?) -> UIColor {
        guard let soc else { return .systemGray }
        return soc < 15 ? .systemRed : soc < 30 ? .systemOrange : .systemGreen
    }

    private func showDetails() {
        let store = AppModel.shared.store
        let e = store.energy, s = store.snapshot
        let items = [
            CPInformationItem(title: String(localized: "Trip"), detail: String(format: "%.1f km · %@ Wh/km", e.tripKm, fmt(e.tripWhPerKm, "%.0f"))),
            CPInformationItem(title: String(localized: "Last 10 km"), detail: "\(fmt(e.last10WhPerKm, "%.0f")) Wh/km"),
            CPInformationItem(title: String(localized: "Last 100 km"), detail: "\(fmt(e.last100WhPerKm, "%.0f")) Wh/km"),
            CPInformationItem(title: String(localized: "Power"), detail: "\(fmt(s.powerKW, "%.1f")) kW"),
            CPInformationItem(title: String(localized: "Battery temperature"), detail: "\(fmt(s.tempMin, "%.0f")) – \(fmt(s.tempMax, "%.0f")) °C"),
            CPInformationItem(title: String(localized: "Remaining"), detail: "\(fmt(store.remainingKWh, "%.1f")) kWh"),
            CPInformationItem(title: String(localized: "Cell spread"), detail: (s.cellMin != nil && s.cellMax != nil)
                ? String(format: "%.0f mV", (s.cellMax! - s.cellMin!) * 1000) : "–"),
        ]
        let info = CPInformationTemplate(title: String(localized: "Details"), layout: .twoColumn, items: items, actions: [])
        interfaceController?.pushTemplate(info, animated: true, completion: nil)
    }
}

/// Draws an arc gauge as an image (for CarPlay tiles).
enum GaugeImage {
    static func render(value: Double?, range: ClosedRange<Double>, zero: Double,
                       text: String, unit: String, positive: UIColor, negative: UIColor) -> UIImage {
        let size = CGSize(width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
            let radius: CGFloat = 50, width: CGFloat = 11
            let start = CGFloat.pi * 0.75, sweep = CGFloat.pi * 1.5
            func angle(_ x: Double) -> CGFloat {
                let f = min(max((x - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
                return start + sweep * CGFloat(f)
            }
            c.setLineCap(.round)
            c.setLineWidth(width)

            c.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
            c.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
            c.strokePath()

            if let value {
                let a0 = angle(zero), a1 = angle(value)
                c.setStrokeColor((value >= zero ? positive : negative).cgColor)
                c.addArc(center: center, radius: radius, startAngle: min(a0, a1),
                         endAngle: max(max(a0, a1), min(a0, a1) + 0.01), clockwise: false)
                c.strokePath()
            }

            let big = UIFont.systemFont(ofSize: 30, weight: .bold)
            let small = UIFont.systemFont(ofSize: 12, weight: .medium)
            let t1 = NSAttributedString(string: text, attributes: [.font: big, .foregroundColor: UIColor.white])
            let t2 = NSAttributedString(string: unit, attributes: [.font: small, .foregroundColor: UIColor.lightGray])
            let s1 = t1.size(), s2 = t2.size()
            t1.draw(at: CGPoint(x: center.x - s1.width / 2, y: center.y - s1.height / 2 - 4))
            t2.draw(at: CGPoint(x: center.x - s2.width / 2, y: center.y + s1.height / 2 - 6))
        }
    }
}
