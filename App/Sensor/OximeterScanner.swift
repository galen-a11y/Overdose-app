import Combine
import CoreBluetooth
import Foundation

/// Finds nearby oximeters for pairing. Separate from the monitoring connection
/// (which owns the state-restoration identifier) and used only in the foreground.
final class OximeterScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let likelyOximeter: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var bluetoothProblem: String?
    @Published var showAllDevices = false

    private var central: CBCentralManager?
    private var isScanning = false

    var visibleDevices: [Device] {
        devices
            .filter { showAllDevices || $0.likelyOximeter }
            .sorted { ($0.likelyOximeter ? 1 : 0, $0.rssi) > ($1.likelyOximeter ? 1 : 0, $1.rssi) }
    }

    func start() {
        isScanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            scanIfReady()
        }
    }

    func stop() {
        isScanning = false
        central?.stopScan()
    }

    private func scanIfReady() {
        guard isScanning, let central, central.state == .poweredOn else { return }
        // Some units don't advertise the service UUID, so scan everything and filter by name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothProblem = nil
            scanIfReady()
        case .poweredOff:
            bluetoothProblem = "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized:
            bluetoothProblem = "Spotter needs Bluetooth permission. Turn it on in Settings > Spotter."
        case .unsupported:
            bluetoothProblem = "This phone doesn't support Bluetooth LE."
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let device = Device(
            id: peripheral.identifier,
            name: name ?? "Unnamed device",
            rssi: RSSI.intValue == 127 ? -100 : RSSI.intValue,
            likelyOximeter: PC60FW.looksLikeOximeter(name: name, advertisedServices: services)
        )
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }
}
