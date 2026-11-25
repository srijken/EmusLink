import SwiftUI

@main
struct EmusLinkApp: App {
    // Wordt ook aangemaakt als iOS de app op de achtergrond start voor Bluetooth.
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                ConsumptionView()
                    .tabItem { Label("Verbruik", systemImage: "chart.bar.xaxis") }
                SettingsView()
                    .tabItem { Label("Instellingen", systemImage: "gearshape") }
            }
            .environmentObject(model.store)
            .preferredColorScheme(.dark)
            .onAppear { model.ble.reconnect() }
        }
    }
}
