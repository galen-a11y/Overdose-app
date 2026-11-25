import XCTest
@testable import SafetyCore

final class AlertEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func reading(_ spo2: Int?, pulse: Int? = 72, pi: Double? = 4, at time: Date) -> PulseReading {
        PulseReading(spo2: spo2, pulseRate: spo2 == nil ? nil : pulse, perfusionIndex: pi, timestamp: time)
    }

    /// Runs a scenario second by second (one reading per second, like the device),
    /// returning every event with the second it happened.
    private func run(
        _ scenario: SensorScenario,
        seconds: Int,
        settings: AlertSettings = .default,
        okAt: Set<Int> = []
    ) -> (engine: AlertEngine, events: [(Int, EngineEvent)]) {
        var engine = AlertEngine(settings: settings)
        engine.start(at: t0)
        var events: [(Int, EngineEvent)] = []
        for second in 1...seconds {
            let now = t0.addingTimeInterval(TimeInterval(second))
            if okAt.contains(second) {
                events += engine.confirmOK(at: now).map { (second, $0) }
            }
            if let r = scenario.reading(elapsed: TimeInterval(second), at: now) {
                events += engine.ingest(r, at: now).map { (second, $0) }
            }
            events += engine.tick(at: now).map { (second, $0) }
        }
        return (engine, events)
    }

    func testNormalReadingsNeverAlert() {
        let result = run(.normal, seconds: 600)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.engine.state, .monitoring)
    }

    func testBriefDipFromMovementIsIgnored() {
        let result = run(.briefDip, seconds: 120)
        XCTAssertTrue(result.events.isEmpty, "\(result.events)")
    }

    func testSuddenDropChecksInAfterTwentySecondsThenAlerts() {
        let result = run(.suddenDrop, seconds: 90)
        // Low from second 10, so the check-in starts at second 30 and alerts at 60.
        XCTAssertEqual(result.events.map(\.0), [30, 60])
        XCTAssertEqual(result.events.first?.1, .checkInStarted(reason: .lowOxygen, deadline: t0.addingTimeInterval(60)))
        XCTAssertEqual(result.events.last?.1, .alertTriggered(reason: .lowOxygen))
        XCTAssertEqual(result.engine.state, .alerted(reason: .lowOxygen, at: t0.addingTimeInterval(60)))
    }

    func testSlowDriftAlertsOnceBelowThresholdLongEnough() {
        let result = run(.slowDrift, seconds: 200)
        guard let first = result.events.first else { return XCTFail("no check-in") }
        // Drops 1 point every 3 s from 96 after 20 s: first below 90 (89) at second 41.
        XCTAssertEqual(first.0, 61)
        XCTAssertEqual(first.1, .checkInStarted(reason: .lowOxygen, deadline: t0.addingTimeInterval(91)))
        XCTAssertEqual(result.events.last?.1, .alertTriggered(reason: .lowOxygen))
    }

    func testFingerOutIsSignalLossNotAllClear() {
        let result = run(.fingerOut, seconds: 90)
        // Last valid reading at second 9, so signal is lost at 24 and the alert goes at 54.
        XCTAssertEqual(result.events.map(\.0), [24, 54])
        XCTAssertEqual(result.events.first?.1, .checkInStarted(reason: .signalLost, deadline: t0.addingTimeInterval(54)))
        XCTAssertEqual(result.events.last?.1, .alertTriggered(reason: .signalLost))
    }

    func testLongRunOfWeakReadingsCountsAsSignalLoss() {
        let result = run(.weakSignal, seconds: 60)
        XCTAssertEqual(result.events.first?.0, 24)
        XCTAssertEqual(result.events.first?.1, .checkInStarted(reason: .signalLost, deadline: t0.addingTimeInterval(54)))
    }

    func testWeakReadingsDoNotClearALowStreak() {
        var engine = AlertEngine()
        engine.start(at: t0)
        // Low for 10 s, a few weak "normal" readings, then low again.
        for s in 1...10 { engine.ingest(reading(85, at: t0 + s), at: t0 + s) }
        for s in 11...13 { engine.ingest(reading(97, pi: 0.1, at: t0 + s), at: t0 + s) }
        var events: [EngineEvent] = []
        for s in 14...25 { events += engine.ingest(reading(85, at: t0 + s), at: t0 + s) }
        XCTAssertEqual(events.first, .checkInStarted(reason: .lowOxygen, deadline: t0 + 21 + 30))
    }

    func testDeviceSilenceTriggersSignalLossWithoutAnyReadings() {
        var engine = AlertEngine()
        engine.start(at: t0)
        XCTAssertTrue(engine.tick(at: t0 + 14).isEmpty)
        XCTAssertEqual(engine.tick(at: t0 + 15), [.checkInStarted(reason: .signalLost, deadline: t0 + 45)])
    }

    func testImOKResumesMonitoringWithFreshWindows() {
        // Sudden drop; person taps OK at second 40, during the check-in.
        let result = run(.suddenDrop, seconds: 100, okAt: [40])
        let kinds = result.events.map(\.1)
        XCTAssertEqual(kinds[0], .checkInStarted(reason: .lowOxygen, deadline: t0 + 60))
        XCTAssertEqual(kinds[1], .checkInCleared)
        // Still low, so a new check-in starts 20 s after OK, at second 60.
        XCTAssertEqual(result.events[2].0, 60)
        XCTAssertEqual(kinds[2], .checkInStarted(reason: .lowOxygen, deadline: t0 + 90))
        XCTAssertEqual(kinds[3], .alertTriggered(reason: .lowOxygen))
    }

    func testRecoveredReadingsDoNotCancelACheckIn() {
        var engine = AlertEngine()
        engine.start(at: t0)
        for s in 1...21 { engine.ingest(reading(85, at: t0 + s), at: t0 + s) }
        guard case .checkIn = engine.state else { return XCTFail("expected check-in") }
        for s in 22...50 { engine.ingest(reading(98, at: t0 + s), at: t0 + s) }
        engine.tick(at: t0 + 51)
        XCTAssertEqual(engine.state, .alerted(reason: .lowOxygen, at: t0 + 51))
    }

    func testOKOutsideCheckInDoesNothing() {
        var engine = AlertEngine()
        engine.start(at: t0)
        XCTAssertTrue(engine.confirmOK(at: t0 + 1).isEmpty)
        XCTAssertEqual(engine.state, .monitoring)
    }

    func testAlertedStateStaysUntilEnded() {
        let result = run(.fingerOut, seconds: 600)
        guard case .alerted = result.engine.state else { return XCTFail("expected alerted") }
        var engine = result.engine
        engine.end()
        XCTAssertEqual(engine.state, .ended)
        XCTAssertFalse(engine.isActive)
    }

    func testTimedSessionRemindsAndExpires() {
        var engine = AlertEngine()
        engine.start(at: t0, duration: 3600)
        var events: [EngineEvent] = []
        for s in stride(from: 1, through: 3600, by: 1) {
            events += engine.ingest(reading(97, at: t0 + s), at: t0 + s)
        }
        XCTAssertEqual(events, [.sessionEndingSoon(endsAt: t0 + 3600), .sessionExpired])
        XCTAssertEqual(engine.state, .ended)
    }

    func testTimedSessionDoesNotExpireDuringCheckIn() {
        var engine = AlertEngine()
        engine.start(at: t0, duration: 60)
        engine.ingest(reading(97, at: t0 + 1), at: t0 + 1)
        // Nothing more arrives: signal-lost check-in at 16, alert at 46, timer passes at 60.
        _ = engine.tick(at: t0 + 16)
        _ = engine.tick(at: t0 + 46)
        XCTAssertEqual(engine.tick(at: t0 + 61), [])
        guard case .alerted = engine.state else { return XCTFail("expected alerted, got \(engine.state)") }
    }

    func testSettingsAreClampedSoMonitoringCannotBeDisabled() {
        let wild = AlertSettings(lowSpO2Threshold: 10, lowSpO2Duration: 9_999, signalLossTimeout: 0, minimumPerfusionIndex: 50, checkInCountdown: 1)
        let engine = AlertEngine(settings: wild)
        XCTAssertEqual(engine.settings.lowSpO2Threshold, 80)
        XCTAssertEqual(engine.settings.lowSpO2Duration, 60)
        XCTAssertEqual(engine.settings.signalLossTimeout, 10)
        XCTAssertEqual(engine.settings.minimumPerfusionIndex, 2)
        XCTAssertEqual(engine.settings.checkInCountdown, 15)
    }

    func testIdleEngineIgnoresReadings() {
        var engine = AlertEngine()
        XCTAssertTrue(engine.ingest(reading(70, at: t0), at: t0).isEmpty)
        XCTAssertTrue(engine.tick(at: t0 + 100).isEmpty)
    }
}

private func + (date: Date, seconds: Int) -> Date {
    date.addingTimeInterval(TimeInterval(seconds))
}
