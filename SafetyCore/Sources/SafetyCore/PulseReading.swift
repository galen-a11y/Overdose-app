import Foundation

/// One reading from a pulse oximeter, already decoded from its wire format.
public struct PulseReading: Equatable, Sendable, Codable {
    /// Oxygen saturation in percent. `nil` means the device sent no usable value
    /// (finger out, still searching, or a value outside 1...100).
    public var spo2: Int?
    /// Pulse rate in beats per minute. `nil` means no usable value.
    public var pulseRate: Int?
    /// Perfusion index (signal strength) in percent. `nil` if the device did not report one.
    public var perfusionIndex: Double?
    /// When the phone received the reading.
    public var timestamp: Date

    public init(spo2: Int?, pulseRate: Int?, perfusionIndex: Double?, timestamp: Date) {
        self.spo2 = spo2
        self.pulseRate = pulseRate
        self.perfusionIndex = perfusionIndex
        self.timestamp = timestamp
    }
}

/// How much the alert engine can trust a reading.
public enum ReadingQuality: Equatable, Sendable {
    /// Oxygen and pulse are present and the signal is strong enough to believe.
    case valid
    /// Values are present but the signal strength is too low to believe them.
    case weak
    /// The device sent nothing usable (finger out, searching, out-of-range values).
    case noData
}

extension PulseReading {
    /// Classifies a reading. Only `.valid` readings count as "the person is being watched".
    public func quality(minimumPerfusionIndex: Double) -> ReadingQuality {
        guard let spo2, (1...100).contains(spo2),
              let pulseRate, (20...250).contains(pulseRate) else {
            return .noData
        }
        // Devices that never report a perfusion index are trusted on oxygen and pulse alone.
        if let perfusionIndex, perfusionIndex < minimumPerfusionIndex {
            return .weak
        }
        return .valid
    }
}

/// Everything a sensor can tell the app. Kept free of Core Bluetooth so the
/// alert logic and the UI can be driven by a fake sensor in tests and previews.
public enum SensorEvent: Equatable, Sendable {
    case searching
    case connecting(name: String)
    case connected(name: String)
    case disconnected(reason: String?)
    case reading(PulseReading)
    /// Battery level from 0 to 100, if the device reports it.
    case battery(percent: Int)
    /// Undecoded bytes, for the raw packet screen used to confirm the device model.
    case rawPacket(Data)
}

/// The app talks to every oximeter through this protocol, so a second device
/// (for example a ring sensor in version 2) can be added without touching the
/// alert logic.
public protocol PulseSensor: AnyObject {
    /// Human-readable device name for the UI.
    var displayName: String { get }
    /// Called on the main queue for every event.
    var onEvent: ((SensorEvent) -> Void)? { get set }
    /// Begin connecting (and keep reconnecting) to the paired device.
    func start()
    /// Disconnect and stop reconnecting.
    func stop()
}
