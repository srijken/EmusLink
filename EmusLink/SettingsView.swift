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
                    Toggle("Versturen naar ABRP", isOn: $abrpOn)
                        .onChange(of: abrpOn) { _, v in model.abrp.enabled = v }
                    TextField("API key (van Iternio)", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    TextField("User token (ABRP → Live data)", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button(saved ? "Opgeslagen ✓" : "Opslaan") {
                        model.abrp.apiKey = apiKey
                        model.abrp.userToken = token
                        saved = true
                    }
                    LabeledContent("Laatste resultaat", value: store.abrpResult)
                    if let d = store.abrpLastSent {
                        LabeledContent("Verstuurd om", value: d.formatted(date: .omitted, time: .standard))
                    }
                } header: { Text("ABRP") } footer: {
                    Text("Houd een veld ingedrukt en kies Plak. Zet de ABRP-plugin op de OVMS uit (script eval abrp.send(0)), anders sturen ze allebei naar dezelfde auto.")
                }

                Section {
                    Toggle("GPS gebruiken", isOn: $useLocation)
                        .onChange(of: useLocation) { _, v in model.location.enabled = v }
                } header: { Text("Locatie") } footer: {
                    Text("Nodig voor snelheid, verbruik per km en de positie in ABRP. Kies bij de vraag van iOS voor ‘Altijd’, dan blijft het werken als de app op de achtergrond staat.")
                }

                Section("Module") {
                    LabeledContent("Status", value: store.connection.rawValue)
                    LabeledContent("Naam", value: store.deviceName ?? "–")
                    TextField("Zoeken op naam", text: $nameFilter)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { model.ble.nameFilter = nameFilter }
                    Toggle("Actief pollen (experimenteel)", isOn: $polling)
                        .onChange(of: polling) { _, v in model.ble.pollingEnabled = v }
                    Button("Opnieuw zoeken / andere module", role: .destructive) { model.ble.forgetDevice() }
                }

                Section("Diagnose") {
                    LabeledContent("Notify", value: store.notifyOn ? "aan" : "uit")
                    LabeledContent("Pakketten", value: "\(store.packets)")
                    LabeledContent("Zinnen geldig / kapot", value: "\(store.validSentences) / \(store.invalidSentences)")
                    LabeledContent("Firmware", value: store.snapshot.firmware ?? "–")
                    if let w = store.writeCharacteristic { LabeledContent("Schrijven via", value: w) }
                }

                Section("Log") {
                    ForEach(Array(store.log.prefix(60).enumerated()), id: \.offset) {
                        Text($0.element).font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("Instellingen")
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
