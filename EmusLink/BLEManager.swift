import Foundation
import CoreBluetooth

/// Connects to the EMUS Smartphone Module and keeps the connection alive in the background too.
/// All Bluetooth processing happens on its own queue; the UI gets an update at most twice per second.
final class BLEManager: NSObject {

    static let serviceUUID = CBUUID(string: "BB460001-4A8B-AA9D-E511-9A19C681CA6B")
    static let notifyUUID  = CBUUID(string: "BB460002-4A8B-AA9D-E511-9A19C681CA6B")
    // CAREFUL: BB460004 is the module's name setting (writing to it renames the module!)
    // and BB460005 is probably configuration as well. Only 0003 may be written to.
    static let writeUUID   = CBUUID(string: "BB460003-4A8B-AA9D-E511-9A19C681CA6B")

    let queue = DispatchQueue(label: "\(AppConfig.bundleID).ble", qos: .userInitiated)
    weak var store: LiveStore?

    /// After every valid sentence, on `queue` (also in the background).
    var onSentence: ((BMSSnapshot, String) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private let assembler = SentenceAssembler()

    // Only touch on `queue`:
    private var snapshot = BMSSnapshot()
    private var packets = 0, valid = 0, invalid = 0
    private var notifyOn = false
    private var lastPublish = Date.distantPast

    // Polling (off by default; the EMUS also broadcasts on its own).
    private let pollSequence = ["BC1", "CV1", "BT3", "BV1"]
    private var pollIndex = 0
    private var lastPoll = Date.distantPast

    private let defaults = UserDefaults.standard
    private var savedPeripheralID: UUID? {
        get { defaults.string(forKey: "peripheralID").flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: "peripheralID") }
    }
    var nameFilter: String {
        get { defaults.string(forKey: "nameFilter") ?? AppConfig.defaultModuleName }
        set { defaults.set(newValue, forKey: "nameFilter") }
    }
    var pollingEnabled: Bool {
        get { defaults.bool(forKey: "pollingEnabled") }
        set { defaults.set(newValue, forKey: "pollingEnabled") }
    }

    /// Must happen at app launch, so iOS can restore the connection.
    func start() {
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "\(AppConfig.bundleID).central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    /// Is this the module? By the EMUS service, or by (part of) the name if one is set.
    static func matches(name: String, services: [CBUUID], nameFilter: String) -> Bool {
        let filter = nameFilter.trimmingCharacters(in: .whitespaces)
        return services.contains(serviceUUID)
            || (!filter.isEmpty && name.localizedCaseInsensitiveContains(filter))
    }

    // MARK: - Controls (from the UI)

    func reconnect() { queue.async { self.startConnecting() } }

    func forgetDevice() {
        queue.async {
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.savedPeripheralID = nil
            self.startConnecting()
        }
    }

    // MARK: - Internal (on queue)

    private func startConnecting() {
        guard let central, central.state == .poweredOn else { return }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }

        if let id = savedPeripheralID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known); return
        }
        if let already = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connect(already); return
        }
        setConnection(.scanning)
        central.scanForPeripherals(withServices: nil, options: nil)
        log(nameFilter.isEmpty ? String(localized: "Searching for EMUS module")
                                : String(localized: "Searching for '\(nameFilter)'"))
    }

    private func connect(_ p: CBPeripheral) {
        central?.stopScan()
        peripheral = p
        p.delegate = self
        setConnection(.connecting, name: p.name)
        central?.connect(p, options: nil)   // no timeout: connects as soon as the module is in range
    }

    private func handle(_ data: Data) {
        packets += 1
        for line in assembler.append(data) {
            guard let fields = EmusProtocol.validate(line) else { invalid += 1; continue }
            valid += 1
            let id = snapshot.apply(fields) ?? "?"
            onSentence?(snapshot, id)
        }
        pollIfNeeded()
        publishIfDue()
    }

    private func pollIfNeeded() {
        guard pollingEnabled, let p = peripheral, p.state == .connected, let w = writeChar else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPoll) >= 1.0 else { return }
        lastPoll = now
        let sentence = pollSequence[pollIndex % pollSequence.count]
        pollIndex += 1
        p.writeValue(EmusProtocol.request(sentence), for: w, type: .withoutResponse)
    }

    private func publishIfDue(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublish) >= 0.5 else { return }
        lastPublish = now
        let (snap, pk, ok, bad, nOn) = (snapshot, packets, valid, invalid, notifyOn)
        DispatchQueue.main.async { [weak store] in
            guard let store else { return }
            store.snapshot = snap
            store.packets = pk
            store.validSentences = ok
            store.invalidSentences = bad
            store.notifyOn = nOn
        }
    }

    private func setConnection(_ state: ConnectionState, name: String? = nil) {
        DispatchQueue.main.async { [weak store] in
            store?.connection = state
            if let name { store?.deviceName = name }
        }
    }

    private func log(_ text: String) {
        DispatchQueue.main.async { [weak store] in store?.addLog(text) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            log(String(localized: "Restored by iOS"))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let p = peripheral, p.state == .connected {
                setConnection(.connected, name: p.name)
                p.discoverServices([Self.serviceUUID])
            } else {
                startConnecting()
            }
        default:
            setConnection(.off)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard Self.matches(name: name, services: services, nameFilter: nameFilter) else { return }
        log(String(localized: "Found: \(name)"))
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        savedPeripheralID = p.identifier
        assembler.reset()
        packets = 0; valid = 0; invalid = 0; notifyOn = false
        setConnection(.connected, name: p.name)
        log(String(localized: "Connected to \(p.name ?? "EMUS")"))
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log(String(localized: "Connecting failed: \(error?.localizedDescription ?? "-")"))
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log(String(localized: "Connection lost") + (error.map { ": \($0.localizedDescription)" } ?? ""))
        notifyOn = false
        publishIfDue(force: true)
        connect(p)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log(String(localized: "Services error: \(error.localizedDescription)")) }
        guard let service = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            log(String(localized: "EMUS service not found")); return
        }
        p.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log(String(localized: "Characteristics error: \(error.localizedDescription)")) }
        let chars = service.characteristics ?? []
        if let n = chars.first(where: { $0.uuid == Self.notifyUUID }) {
            p.setNotifyValue(true, for: n)
        }
        writeChar = chars.first(where: { $0.uuid == Self.writeUUID })
        let name = writeChar.map { String($0.uuid.uuidString.prefix(8)) }
        DispatchQueue.main.async { [weak store] in store?.writeCharacteristic = name }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            log(String(localized: "Notify error: \(error.localizedDescription)"))
        } else {
            notifyOn = c.isNotifying
            log(c.isNotifying ? String(localized: "Notify on") : String(localized: "Notify off"))
            publishIfDue(force: true)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Self.notifyUUID, let data = c.value else { return }
        handle(data)
    }
}
