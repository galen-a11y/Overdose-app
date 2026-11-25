import Foundation
import SafetyCore

/// A scripted sensor for testing without the device (Settings > Developer).
/// It sends real PC-60FW frames through the real decoder, so the raw packet
/// screen and the decoding path are exercised too.
final class FakePulseSensor: PulseSensor {
    var onEvent: ((SensorEvent) -> Void)?
    var displayName: String { "Fake oximeter (\(scenario.title))" }

    let scenario: SensorScenario
    private var timer: Timer?
    private var startedAt = Date()
    private var decoder = PC60FWDecoder()
    private var isSilent = false

    init(scenario: SensorScenario) {
        self.scenario = scenario
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        isSilent = false
        onEvent?(.connected(name: displayName))
        onEvent?(.battery(percent: 100))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.emit() }
    }

    /// Starts the scenario over, so it lines up with the start of a session.
    func restartScenario() {
        startedAt = Date()
        isSilent = false
        onEvent?(.connected(name: displayName))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func emit() {
        let now = Date()
        guard let reading = scenario.reading(elapsed: now.timeIntervalSince(startedAt), at: now) else {
            if !isSilent {
                isSilent = true
                onEvent?(.disconnected(reason: "Fake oximeter powered off"))
            }
            return
        }
        let frame = PC60FWDecoder.encode(
            token: PC60FWDecoder.tokenOximeter,
            type: 0x01,
            content: [
                UInt8(reading.spo2 ?? 0),
                UInt8((reading.pulseRate ?? 0) & 0xFF),
                UInt8((reading.pulseRate ?? 0) >> 8),
                UInt8(((reading.perfusionIndex ?? 0) * 10).rounded()),
                reading.spo2 == nil ? 0x02 : 0x00,
                0x00,
            ]
        )
        onEvent?(.rawPacket(frame))
        for decoded in decoder.feed(frame) {
            if let reading = decoded.reading(at: now) { onEvent?(.reading(reading)) }
        }
    }
}
