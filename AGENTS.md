# AGENTS.md

Aanwijzingen voor AI-agents (en mensen) die aan deze repo werken. Zie [README.md](README.md) voor wat de app doet en voor het EMUS-protocol.

## Wat dit is

iOS-app (SwiftUI, iOS 17+, alleen iPhone) die de EMUS G1 BMS van een elektrische Defender via Bluetooth LE uitleest, verbruik per km bijhoudt en de SoC naar ABRP stuurt. Ook op de achtergrond en met een CarPlay-scherm. Geen externe dependencies.

## Bouwen

Het Xcode-project staat **niet** in git: het wordt door [XcodeGen](https://github.com/yonaskolb/XcodeGen) gemaakt uit `project.yml`.

```sh
xcodegen                     # na elke wijziging in project.yml of bij nieuwe/verwijderde bestanden
xcodebuild -project EmusLink.xcodeproj -scheme EmusLink \
  -destination 'generic/platform=iOS Simulator' build
```

- Wijzig build-instellingen in `project.yml`, nooit in `EmusLink.xcodeproj`.
- Zonder `Config/Local.xcconfig` bouwt het project voor de simulator met de standaardwaarden uit `Config/Shared.xcconfig`. Voor een iPhone is een eigen `DEVELOPMENT_TEAM` nodig.
- `EmusLink/Info.plist` wordt door XcodeGen overschreven: pas `info.properties` in `project.yml` aan.

## Testen

```sh
xcodegen
xcodebuild test -project EmusLink.xcodeproj -scheme EmusLink \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

(Neem een simulator die geïnstalleerd is: `xcrun simctl list devices available`.)

- Unit tests staan in `EmusLinkTests/` (XCTest, `@testable import EmusLink`), één bestand per onderdeel.
- Draai de tests na elke wijziging en voeg tests toe bij nieuwe logica of een opgeloste bug. Getest worden: het protocol (CRC, zinnen, decodering), `EnergyTracker` (gemiddelden, ritten, de punten van de verbruiksgrafiek), `LiveStore` (range) en de ABRP-telemetrie en -URL.
- Houd logica testbaar: rekenwerk hoort in `EmusProtocol`, `EnergyTracker`, `LiveStore` of een statische functie, niet in een View of in een CoreBluetooth-delegate. Geef tijd (`now:`/`at:`) en `UserDefaults` als parameter mee in plaats van `Date()` en `.standard` vast te zetten; tests gebruiken een eigen `UserDefaults(suiteName:)`.
- De tests draaien in de app in de simulator (demo-modus). Niet automatisch getest: Bluetooth, GPS, CarPlay en de opmaak van de schermen. Controleer die in de simulator of op de iPhone.

## Opbouw

| Bestand | Rol |
| --- | --- |
| `EmusProtocol.swift` | CRC-8, zinnen valideren, `SentenceAssembler` (BLE-pakketjes → regels), `BMSSnapshot` (decodering) |
| `BLEManager.swift` | CoreBluetooth: zoeken, verbinden, herstellen op de achtergrond, pollen |
| `EnergyTracker.swift` | Verbruik: ∫U·I dt uit de BMS, afstand uit GPS, segmenten van 100 m, ritten |
| `ABRPClient.swift` | Telemetrie naar de ABRP/Iternio-API |
| `LocationProvider.swift` | GPS |
| `LiveStore.swift` | `ObservableObject` met alles wat de schermen tonen (alleen main thread) |
| `AppConfig.swift` | Standaardwaarden uit de build-configuratie (xcconfig → Info.plist) |
| `AppModel.swift` | Koppelt alles aan elkaar (singleton); demo-data in de simulator |
| `DashboardView`, `ConsumptionView`, `SettingsView`, `Gauges` | SwiftUI-schermen |
| `CarPlaySceneDelegate.swift` | CarPlay (Driving Task, alleen templates) |

## Afspraken

- **Taal**: commentaar, UI-teksten en commitberichten zijn in het Nederlands.
- **Threads**: Bluetooth-verwerking draait op `BLEManager.queue`; `LiveStore` wordt alleen op de main thread bijgewerkt (max. een paar keer per seconde). `EnergyTracker`, `ABRPClient` en `LocationProvider` zijn thread-safe met een `NSLock`. Houd dat zo.
- **Tekens en eenheden**: stroom uit de BMS is positief bij laden; vermogen en verbruik volgen de ABRP-conventie (positief = verbruik, negatief = laden/regeneratie). Verbruik in Wh/km.
- **Schrijven naar de module**: alleen naar characteristic `BB460003`. `BB460004` is de naam-instelling van de module (schrijven hernoemt hem!) en `0005` is vermoedelijk ook configuratie. Niet aankomen.
- **Simulator**: geen Bluetooth; `AppModel` draait daar met nepdata. Echte BLE-communicatie is alleen op een iPhone bij de auto te testen.

## Configuratie en secrets

- De repo is bedoeld om openbaar te kunnen staan. **Commit nooit** een Team ID, eigen bundle identifier, ABRP API key, user token, of de naam van iemands module.
- Persoonlijke waarden staan in `Config/Local.xcconfig` (in `.gitignore`; voorbeeld in `Config/Local.xcconfig.example`). `Config/Shared.xcconfig` bevat alleen neutrale standaardwaarden en laadt het lokale bestand.
- Een nieuwe instelling toevoegen: standaardwaarde in `Shared.xcconfig`, voorbeeld in `Local.xcconfig.example`, doorgeven via `info.properties` in `project.yml`, uitlezen in `AppConfig.swift`, en beschrijven in de README. Zet zulke waarden niet vast in Swift-code.
- De ABRP API key en het user token worden normaal in de app ingevuld en staan in `UserDefaults`; de waarden uit de xcconfig zijn alleen een startwaarde.
- `Config/Local.xcconfig` en `EmusLink.xcodeproj` (bevat de lokale waarden niet, maar is gegenereerd) nooit met `git add -f` toevoegen.
