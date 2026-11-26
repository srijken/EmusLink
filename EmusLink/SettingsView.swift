import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: LiveStore
    private let model = AppModel.shared

    @State private var apiKey = ""
    @State private var token = ""
    @State private var nameFilter = ""
    @State private var polling = false
    @State private var useLocation = true
    @State private var abrpOn = true
    @State private var saved = false
    @State private var tempAlert = true
    @State private var liveActivity = true
    @State private var tempLow = TemperatureMonitor.defaultLow
    @State private var tempHigh = TemperatureMonitor.defaultHigh

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Send to ABRP", isOn: $abrpOn)
                        .onChange(of: abrpOn) { _, v in model.abrp.enabled = v }
                    TextField("API key (from Iternio)", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    TextField("User token (ABRP → Live data)", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button(saved ? LocalizedStringKey("Saved ✓") : LocalizedStringKey("Save")) {
                        model.abrp.apiKey = apiKey
                        model.abrp.userToken = token
                        saved = true
                    }
                    LabeledContent("Last result", value: store.abrpResult)
                    if let d = store.abrpLastSent {
                        LabeledContent("Sent at", value: d.formatted(date: .omitted, time: .standard))
                    }
                    if store.abrpPending > 0 {
                        LabeledContent("Waiting to be sent", value: "\(store.abrpPending)")
                        Button("Discard waiting data", role: .destructive) {
                            model.abrp.queue.clear()
                            store.abrpPending = 0
                        }
                    }
                } header: { Text("ABRP") } footer: {
                    Text("Touch and hold a field and choose Paste. Switch off the ABRP plugin on the OVMS (script eval abrp.send(0)), otherwise both send data for the same car. Without network the data waits (up to 24 hours) and is sent once there is network again, oldest first.")
                }

                Section {
                    Toggle("Use GPS", isOn: $useLocation)
                        .onChange(of: useLocation) { _, v in model.location.enabled = v }
                } header: { Text("Location") } footer: {
                    Text("Needed for speed, consumption per km and the position in ABRP. When iOS asks, choose ‘Always’ so it keeps working while the app is in the background.")
                }

                Section {
                    Toggle("Live Activity while driving", isOn: $liveActivity)
                        .onChange(of: liveActivity) { _, v in model.liveActivity.enabled = v }
                } header: { Text("Live Activity") } footer: {
                    Text("Battery, range and consumption on the lock screen, in the Dynamic Island and on the CarPlay screen. It starts when the app or its CarPlay screen is open while the module is connected, and ends two minutes after the car is switched off.")
                }

                Section {
                    Toggle("Warn about battery temperature", isOn: $tempAlert)
                        .onChange(of: tempAlert) { _, v in
                            model.temperature.enabled = v
                            model.temperatureSettingsChanged()
                        }
                    Stepper(value: $tempLow, in: -30...20, step: 1) {
                        LabeledContent("Too cold at", value: String(format: "%.0f °C", tempLow))
                    }
                    .onChange(of: tempLow) { _, v in
                        model.temperature.lowLimit = v
                        model.temperatureSettingsChanged()
                    }
                    Stepper(value: $tempHigh, in: 30...65, step: 1) {
                        LabeledContent("Too hot at", value: String(format: "%.0f °C", tempHigh))
                    }
                    .onChange(of: tempHigh) { _, v in
                        model.temperature.highLimit = v
                        model.temperatureSettingsChanged()
                    }
                } header: { Text("Temperature warning") } footer: {
                    Text("A notification and a banner (also on CarPlay) when the coldest or warmest part of the battery passes a limit. Check your battery's data sheet for its own limits.")
                }

                Section("Module") {
                    LabeledContent("Status", value: store.connection.label)
                    LabeledContent("Name", value: store.deviceName ?? "–")
                    TextField("Search by name", text: $nameFilter)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { model.ble.nameFilter = nameFilter }
                    Toggle("Active polling (experimental)", isOn: $polling)
                        .onChange(of: polling) { _, v in model.ble.pollingEnabled = v }
                    Button("Search again / other module", role: .destructive) { model.ble.forgetDevice() }
                }

                Section("Diagnostics") {
                    LabeledContent("Notify", value: store.notifyOn ? String(localized: "on") : String(localized: "off"))
                    LabeledContent("Packets", value: "\(store.packets)")
                    LabeledContent("Sentences valid / broken", value: "\(store.validSentences) / \(store.invalidSentences)")
                    LabeledContent("Firmware", value: store.snapshot.firmware ?? "–")
                    if let w = store.writeCharacteristic { LabeledContent("Writing via", value: w) }
                }

                Section {
                    if let last = model.backup.lastBackup {
                        LabeledContent("Last backup", value: last.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("Last backup", value: model.backup.isReady
                                       ? String(localized: "not yet") : String(localized: "waiting for iCloud"))
                    }
                } header: { Text("iCloud") } footer: {
                    Text("The learned data and the settings are copied to your iCloud every few minutes and restored after a reinstall or on a new iPhone. After a fresh install the app waits up to 10 minutes for the backup before it writes a new one.")
                }

                Section("About") {
                    LabeledContent("Version", value: AppConfig.version)
                    if let built = AppConfig.buildDate {
                        LabeledContent("Built", value: built.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Bundle ID", value: AppConfig.bundleID)
                }

                Section("Log") {
                    ForEach(Array(store.log.prefix(60).enumerated()), id: \.offset) {
                        Text($0.element).font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .onAppear {
            apiKey = model.abrp.apiKey
            token = model.abrp.userToken
            nameFilter = model.ble.nameFilter
            polling = model.ble.pollingEnabled
            useLocation = model.location.enabled
            abrpOn = model.abrp.enabled
            tempAlert = model.temperature.enabled
            liveActivity = model.liveActivity.enabled
            tempLow = model.temperature.lowLimit
            tempHigh = model.temperature.highLimit
            saved = false
        }
    }
}
