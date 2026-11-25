import Combine
import Foundation
import SafetyCore

/// Owns whichever sensor is in use (the paired oximeter or the fake one) and
/// publishes its state for the UI. Readings are forwarded to the session.
final class SensorHub: ObservableObject {
    enum Status: Equatable {
        case notPaired
        case idle
        case searching
        case connecting
        case connected
        case disconnected(String?)

        var label: String {
            switch self {
            case .notPaired: return "No oximeter paired"
            case .idle: return "Not connected"
            case .searching: return "Looking for oximeter"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case let .disconnected(reason): return reason ?? "Disconnected"
            }
        }
    }

    @Published private(set) var status: Status = .notPaired
    @Published private(set) var latest: PulseReading?
    @Published private(set) var batteryPercent: Int?
    /// Last raw notifications in hex, newest first, for the raw packet screen.
    @Published private(set) var rawLog: [String] = []
    @Published private(set) var sensorName: String = ""

    /// Called for every reading, valid or not.
    var onReading: ((PulseReading) -> Void)?
    /// Called on connect and disconnect.
    var onConnectionChange: ((Bool) -> Void)?

    private(set) var sensor: PulseSensor?
    private var users = Set<String>()
    private static let rawLogLimit = 60

    /// Rebuilds the sensor from saved settings (after pairing or switching to the fake one).
    func configure(with data: AppData) {
        let wasRunning = !users.isEmpty
        sensor?.stop()
        sensor = nil
        latest = nil
        batteryPercent = nil

        if data.useFakeSensor {
            sensor = FakePulseSensor(scenario: data.fakeScenario)
        } else if let id = data.pairedSensorID {
            sensor = PC60FWSensor(pairedID: id, name: data.pairedSensorName)
        }
        sensorName = sensor?.displayName ?? ""
        status = sensor == nil ? .notPaired : .idle
        sensor?.onEvent = { [weak self] event in self?.handle(event) }
        if wasRunning { sensor?.start() }
    }

    /// Starts the sensor for a named user (pairing check, a session). It stays
    /// on until every user has released it.
    func acquire(_ user: String) {
        users.insert(user)
        sensor?.start()
    }

    func release(_ user: String) {
        users.remove(user)
        if users.isEmpty {
            sensor?.stop()
            if sensor != nil { status = .idle }
        }
    }

    var decoderSummary: String? {
        guard let real = sensor as? PC60FWSensor else { return nil }
        let stats = real.decoderStats
        return "\(stats.frames) frames decoded, \(stats.checksumFailures) checksum failures"
    }

    private func handle(_ event: SensorEvent) {
        switch event {
        case .searching:
            status = .searching
        case let .connecting(name):
            sensorName = name
            status = .connecting
        case let .connected(name):
            sensorName = name
            status = .connected
            onConnectionChange?(true)
        case let .disconnected(reason):
            status = .disconnected(reason)
            onConnectionChange?(false)
        case let .reading(reading):
            latest = reading
            onReading?(reading)
        case let .battery(percent):
            batteryPercent = percent
        case let .rawPacket(data):
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            let stamp = Self.stampFormatter.string(from: Date())
            rawLog.insert("\(stamp)  \(hex)", at: 0)
            if rawLog.count > Self.rawLogLimit { rawLog.removeLast(rawLog.count - Self.rawLogLimit) }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
