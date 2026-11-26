import SwiftUI

@main
struct EmusLinkApp: App {
    // Also created when iOS launches the app in the background for Bluetooth.
    private let model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                ConsumptionView()
                    .tabItem { Label("Consumption", systemImage: "chart.bar.xaxis") }
                InsightsView()
                    .tabItem { Label("Insights", systemImage: "lightbulb") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(model.store)
            .preferredColorScheme(.dark)
            .onAppear {
                model.ble.reconnect()
                AlertNotifier.setUp()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.health.flush() }
        }
    }
}
