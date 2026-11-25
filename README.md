# EmusLink

iOS-app die de EMUS G1 BMS van de elektrische Defender via de EMUS Smartphone Module (BLE) uitleest en de SoC naar ABRP stuurt, ook op de achtergrond.

## Bouwen

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # en vul je eigen waarden in
xcodegen
open EmusLink.xcodeproj
```

iPhone aansluiten en **Run**. Het Xcode-project wordt door XcodeGen gemaakt uit `project.yml` en staat niet in git: draai `xcodegen` opnieuw na een wijziging in `project.yml`, in `Config/` of bij nieuwe bestanden.

## Eigen instellingen

Alles wat per persoon of per auto verschilt staat in `Config/Local.xcconfig`. Dat bestand komt niet in git.

| Instelling | Betekenis |
| --- | --- |
| `APP_BUNDLE_ID` | Bundle identifier van de app |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID voor signing |
| `DEFAULT_MODULE_NAME` | Naam (of een deel ervan) van de EMUS-module; leeg = alleen zoeken op de EMUS-service |
| `ABRP_API_KEY`, `ABRP_USER_TOKEN` | Optioneel: al ingevuld bij een verse installatie |

De ABRP-gegevens en de naam van de module zijn ook in de app zelf in te stellen (zie hieronder); wat daar is opgeslagen gaat voor.

## Testen

```sh
xcodebuild test -project EmusLink.xcodeproj -scheme EmusLink -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

De unit tests staan in `EmusLinkTests/`. Zie [AGENTS.md](AGENTS.md) voor de opbouw en de afspraken.

## Schermen

- **Dashboard**: accu-% met range, verbruiks- en snelheidsmeter, tegels met vermogen, gemiddeld verbruik, spanning, temperatuur en cellen.
- **Verbruik**: grafiek per km (laatste 30 km), gemiddelden van rit / 10 km / 100 km, nieuwe rit.
- **Instellingen**: ABRP, GPS, module, diagnose en log.

## CarPlay

Vier tegels (verbruik, snelheid, accu, range); tikken geeft details. Werkt in de simulator
(*I/O → External Displays → CarPlay*, met nepdata). Op de iPhone pas als Apple de
**Driving Task**-entitlement goedkeurt (developer.apple.com/contact/carplay); haal daarna
de `[sdk=iphonesimulator*]`-beperking in `project.yml` weg.

## Instellen in de app

- **API key**: aanvragen bij Iternio (contact@iternio.com, "Telemetry-only key", gratis).
- **User token**: ABRP → auto-instellingen → Live data → token aanmaken.
- **Naam van de module**: standaard de waarde van `DEFAULT_MODULE_NAME`. Een deel van de naam is genoeg.
- Zet de OVMS-plugin uit (`script eval abrp.send(0)`) of gebruik een ander token, anders sturen ze allebei data naar dezelfde auto.

## Protocol (afgeleid uit de logs van 22-11-2026)

- Service `BB460001-4A8B-AA9D-E511-9A19C681CA6B`, notify `BB460002`, schrijfkandidaten `0003`–`0005`.
- Zinnen eindigen op `,XX\r\n`; `XX` = CRC-8/MAXIM (poly 0x31 gereflecteerd, init 0) over alles t/m de laatste komma.
- Verzoek: `BC1,?,E1` (`VR1,?,D7`, `CV1,?,78`, `BV1,?,4F`, `BT3,?,CB`).
- `BC1`: lading (As), capaciteit (As), SoC (0,01 %), SoH (0,01 %).
- `CV1`: packspanning (0,01 V), stroom (signed, 0,1 A).
- `BV1`: aantal cellen, min/max/gem (2,00 V + n × 0,01 V), packspanning.
- `BT3`: aantal, min/max/gem temperatuur (n − 100 °C).

De EMUS zendt deze zinnen ook uit zichzelf; ongeveer 40 % komt heel over BLE binnen, de rest wordt op CRC weggegooid. Dat is genoeg voor een SoC-update om de paar seconden. Pollen staat daarom standaard uit.
