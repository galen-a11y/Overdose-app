import CoreBluetooth
import Foundation
import SafetyCore

/// Bluetooth UUIDs for the PC-60FW family (Nordic UART Service).
enum PC60FW {
    static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let notify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    /// Name fragments the family advertises under ("PC-60F_SN...", "OxySmart", "POD-1W" and similar).
    static let namePatterns = ["PC-60", "PC60", "OXYSMART", "POD", "PC-68"]

    static func looksLikeOximeter(name: String?, advertisedServices: [CBUUID]) -> Bool {
        if advertisedServices.contains(service) { return true }
        guard let upper = name?.uppercased() else { return false }
        return namePatterns.contains { upper.contains($0) }
    }
}

/// The real oximeter, over Core Bluetooth.
///
/// - Uses state restoration, so iOS can relaunch the app for Bluetooth events
///   after it was suspended or killed by the system (not if the person swiped it away).
/// - Keeps a pending connection open whenever monitoring wants one. A pending
///   connection never times out, so when the oximeter powers back on (finger back
///   in) iOS reconnects on its own, even in the background.
final class PC60FWSensor: NSObject, PulseSensor, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let restoreIdentifier = "spotter.oximeter.central"

    var onEvent: ((SensorEvent) -> Void)?
    private(set) var displayName: String

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var decoder = PC60FWDecoder()
    private let pairedID: UUID
    private var wantsConnection = false

    init(pairedID: UUID, name: String?) {
        self.pairedID = pairedID
        self.displayName = name ?? "Oximeter"
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    /// Decoder counters, for the raw packet screen.
    var decoderStats: (frames: Int, checksumFailures: Int) {
        (decoder.framesDecoded, decoder.checksumFailures)
    }

    func start() {
        wantsConnection = true
        connectIfPossible()
    }

    func stop() {
        wantsConnection = false
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    private func connectIfPossible() {
        guard wantsConnection, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected {
            subscribe(peripheral)
            return
        }
        if peripheral == nil {
            peripheral = central.retrievePeripherals(withIdentifiers: [pairedID]).first
        }
        if let peripheral {
            peripheral.delegate = self
            onEvent?(.connecting(name: displayName))
            central.connect(peripheral, options: nil)
        } else {
            // Not seen by this phone since a reset; find it again.
            onEvent?(.searching)
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func subscribe(_ peripheral: CBPeripheral) {
        if let characteristic = peripheral.services?
            .first(where: { $0.uuid == PC60FW.service })?
            .characteristics?.first(where: { $0.uuid == PC60FW.notify }) {
            peripheral.setNotifyValue(true, for: characteristic)
        } else {
            peripheral.discoverServices([PC60FW.service])
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectIfPossible()
        case .poweredOff:
            onEvent?(.disconnected(reason: "Bluetooth is off"))
        case .unauthorized:
            onEvent?(.disconnected(reason: "Bluetooth permission is off. Turn it on in Settings > Spotter."))
        case .unsupported:
            onEvent?(.disconnected(reason: "This phone doesn't support Bluetooth LE"))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == pairedID }) {
            peripheral = restored
            restored.delegate = self
            // iOS only restores us while monitoring was on, so keep wanting it.
            wantsConnection = true
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.identifier == pairedID else { return }
        central.stopScan()
        self.peripheral = peripheral
        connectIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        decoder.reset()
        displayName = peripheral.name ?? displayName
        onEvent?(.connected(name: displayName))
        subscribe(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onEvent?(.disconnected(reason: error?.localizedDescription))
        retrySoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onEvent?(.disconnected(reason: error?.localizedDescription ?? "Oximeter turned off or out of range"))
        if wantsConnection {
            // Reconnect immediately; iOS completes it whenever the device comes back.
            central.connect(peripheral, options: nil)
        }
    }

    private func retrySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectIfPossible() }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PC60FW.service }) else {
            onEvent?(.disconnected(reason: "This device doesn't look like a PC-60FW oximeter"))
            return
        }
        peripheral.discoverCharacteristics([PC60FW.notify], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == PC60FW.notify }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        onEvent?(.rawPacket(data))
        let now = Date()
        for frame in decoder.feed(data) {
            switch frame {
            case .measurement:
                if let reading = frame.reading(at: now) { onEvent?(.reading(reading)) }
            case let .battery(level):
                onEvent?(.battery(percent: PC60FWDecoder.Frame.batteryPercent(level: level)))
            case .waveform, .workingStatus, .other:
                break
            }
        }
    }
}
