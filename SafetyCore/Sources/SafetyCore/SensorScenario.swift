import Foundation

/// Scripted oximeter behaviour for the fake sensor and for tests, so every alert
/// path can be exercised without the real device.
public enum SensorScenario: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Steady 97%, pulse 72.
    case normal
    /// Oxygen drifts down about one point every 3 seconds after 20 seconds, to the low 80s.
    case slowDrift
    /// Normal for 10 seconds, then a sudden drop to 82%.
    case suddenDrop
    /// Normal for 10 seconds, then the finger comes out: probe-off frames for 5 seconds, then the device powers off (nothing at all).
    case fingerOut
    /// Normal for 10 seconds, then values with very low signal strength (cold hands, movement).
    case weakSignal
    /// A 10-second dip to 86% from movement, then back to normal. Should never alert.
    case briefDip

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .slowDrift: return "Slow drift down"
        case .suddenDrop: return "Sudden drop"
        case .fingerOut: return "Finger out, device off"
        case .weakSignal: return "Weak signal"
        case .briefDip: return "Brief dip (no alert)"
        }
    }

    /// The reading the device would send `elapsed` seconds into the scenario,
    /// or `nil` if it would send nothing at all (powered off).
    public func reading(elapsed: TimeInterval, at timestamp: Date) -> PulseReading? {
        func values(_ spo2: Int, _ pulse: Int = 72, pi: Double = 4.0) -> PulseReading {
            PulseReading(spo2: spo2, pulseRate: pulse, perfusionIndex: pi, timestamp: timestamp)
        }
        let empty = PulseReading(spo2: nil, pulseRate: nil, perfusionIndex: nil, timestamp: timestamp)

        switch self {
        case .normal:
            return values(97)
        case .slowDrift:
            guard elapsed > 20 else { return values(96) }
            let drop = Int((elapsed - 20) / 3)
            return values(max(82, 96 - drop), 64 - min(drop, 20))
        case .suddenDrop:
            return elapsed < 10 ? values(97) : values(82, 52)
        case .fingerOut:
            if elapsed < 10 { return values(97) }
            if elapsed < 15 { return empty }
            return nil
        case .weakSignal:
            return elapsed < 10 ? values(97) : values(91, 70, pi: 0.1)
        case .briefDip:
            return (10..<20).contains(elapsed) ? values(86) : values(97)
        }
    }
}
