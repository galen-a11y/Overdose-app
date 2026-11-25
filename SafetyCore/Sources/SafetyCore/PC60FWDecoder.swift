import Foundation

/// Decodes the Bluetooth byte stream from a Wellue / Viatom PC-60FW family oximeter
/// (also sold as the Bluetooth OxySmart).
///
/// Wire format, cross-checked against Viatom's own Android SDK (LepuBle,
/// `PC60FwBleResponse.kt` and `Pc60FwBleInterface.kt`) and the community decoder
/// listed in docs/SPEC.md:
///
///     AA 55 <token> <len> <type> <content...> <crc>
///
/// - `token` is 0x0F for oximeter data or 0xF0 for device information.
/// - `len` counts `type`, `content` and `crc`, so the whole frame is `4 + len` bytes.
/// - `crc` is CRC-8/Maxim over every byte before it, sync bytes included.
///
/// Frames we use:
/// - 0x0F / 0x01, measurement: `spo2, pr_lo, pr_hi, pi(x10), status, ?`.
///   Status bit 1 means the probe is off (no finger); bit 2 means still searching for a pulse.
/// - 0x0F / 0x02, waveform: five samples (ignored, shown on the raw screen only).
/// - 0x0F / 0x21, working status: mode (1 spot check, 2 continuous, 3 menu), step, ...
/// - 0xF0 / 0x03, battery level 0 to 3.
///
/// Bluetooth notifications can split or join frames, so the decoder buffers bytes
/// and resynchronizes on the next `AA 55` whenever it sees garbage or a bad checksum.
public struct PC60FWDecoder {
    public enum Frame: Equatable, Sendable {
        case measurement(spo2: Int, pulseRate: Int, perfusionIndex: Double, probeOff: Bool, searching: Bool)
        case waveform([UInt8])
        case workingStatus(mode: Int, step: Int)
        /// Battery level as reported, 0 (empty) to 3 (full).
        case battery(level: Int)
        case other(token: UInt8, type: UInt8, content: [UInt8])
    }

    public static let tokenOximeter: UInt8 = 0x0F
    public static let tokenDeviceInfo: UInt8 = 0xF0

    private var buffer: [UInt8] = []
    /// Frames dropped because their checksum did not match. Shown on the raw packet screen.
    public private(set) var checksumFailures = 0
    /// Frames accepted. Shown on the raw packet screen.
    public private(set) var framesDecoded = 0

    /// Upper bound so a stream of junk can never grow the buffer without limit.
    private static let maxBuffer = 1024

    public init() {}

    /// Feeds newly received bytes and returns every complete, valid frame in order.
    public mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        if buffer.count > Self.maxBuffer {
            buffer.removeFirst(buffer.count - Self.maxBuffer)
        }

        var frames: [Frame] = []
        var index = 0
        while index + 4 <= buffer.count {
            guard buffer[index] == 0xAA, buffer[index + 1] == 0x55 else {
                index += 1
                continue
            }
            let token = buffer[index + 2]
            let length = Int(buffer[index + 3])
            guard (token == Self.tokenOximeter || token == Self.tokenDeviceInfo), length >= 2 else {
                // Not a real frame start; keep scanning from the next byte.
                index += 1
                continue
            }
            let end = index + 4 + length
            guard end <= buffer.count else {
                break // Wait for the rest of this frame.
            }
            let frameBytes = Array(buffer[index..<end])
            if Self.crc8Maxim(frameBytes.dropLast()) == frameBytes.last {
                framesDecoded += 1
                frames.append(Self.parse(token: token, type: frameBytes[4], content: Array(frameBytes[5..<(end - index - 1)])))
                index = end
            } else {
                checksumFailures += 1
                index += 1
            }
        }
        buffer.removeFirst(index)
        return frames
    }

    public mutating func reset() {
        buffer.removeAll()
    }

    static func parse(token: UInt8, type: UInt8, content: [UInt8]) -> Frame {
        switch (token, type) {
        case (tokenOximeter, 0x01) where content.count >= 5:
            let spo2 = Int(content[0])
            let pulseRate = Int(content[1]) | (Int(content[2]) << 8)
            let perfusionIndex = Double(content[3]) / 10.0
            let status = content[4]
            return .measurement(
                spo2: spo2,
                pulseRate: pulseRate,
                perfusionIndex: perfusionIndex,
                probeOff: status & 0x02 != 0,
                searching: status & 0x04 != 0
            )
        case (tokenOximeter, 0x02):
            return .waveform(content.map { $0 & 0x7F })
        case (tokenOximeter, 0x21) where content.count >= 2:
            return .workingStatus(mode: Int(content[0]), step: Int(content[1]))
        case (tokenDeviceInfo, 0x03) where content.count >= 1:
            return .battery(level: Int(content[0]))
        default:
            return .other(token: token, type: type, content: content)
        }
    }

    /// CRC-8/Maxim (Dallas 1-Wire): reflected polynomial 0x8C, initial value 0.
    /// Same table as `CrcUtil.calCRC8Pc` in Viatom's SDK.
    public static func crc8Maxim<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            var value = crc ^ byte
            for _ in 0..<8 {
                value = (value & 0x01) != 0 ? (value >> 1) ^ 0x8C : value >> 1
            }
            crc = value
        }
        return crc
    }

    /// Builds a valid frame. Used by tests and by the fake sensor.
    public static func encode(token: UInt8, type: UInt8, content: [UInt8]) -> Data {
        var bytes: [UInt8] = [0xAA, 0x55, token, UInt8(content.count + 2), type]
        bytes.append(contentsOf: content)
        bytes.append(crc8Maxim(bytes))
        return Data(bytes)
    }
}

extension PC60FWDecoder.Frame {
    /// Converts a measurement frame into the sensor-neutral reading the alert engine uses.
    /// Probe-off and searching frames become readings with no values, which the engine
    /// treats as "no data" (signal loss if it lasts), never as "all clear".
    public func reading(at timestamp: Date) -> PulseReading? {
        guard case let .measurement(spo2, pulseRate, perfusionIndex, probeOff, searching) = self else {
            return nil
        }
        if probeOff || searching || spo2 == 0 || spo2 > 100 || pulseRate == 0 {
            return PulseReading(spo2: nil, pulseRate: nil, perfusionIndex: nil, timestamp: timestamp)
        }
        return PulseReading(spo2: spo2, pulseRate: pulseRate, perfusionIndex: perfusionIndex, timestamp: timestamp)
    }

    /// Maps the device's 0...3 battery level to an approximate percentage for display.
    public static func batteryPercent(level: Int) -> Int {
        switch level {
        case ..<1: return 5
        case 1: return 33
        case 2: return 66
        default: return 100
        }
    }
}
