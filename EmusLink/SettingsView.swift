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
                } header: { Text("ABRP") } footer: {
                    Text("Touch and hold a field and choose Paste. Switch off the ABRP plugin on the OVMS (script eval abrp.send(0)), otherwise both send data for the same car.")
                }

                Section {
                    Toggle("Use GPS", isOn: $useLocation)
                        .onChange(of: useLocation) { _, v in model.location.enabled = v }
                } header: { Text("Location") } footer: {
                    Text("Needed for speed, consumption per km and the position in ABRP. When iOS asks, choose ‘Always’ so it keeps working while the app is in the background.")
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
            saved = false
        }
    }
}
