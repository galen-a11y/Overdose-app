import Foundation

/// The alert rules from docs/SPEC.md ("Alert logic"). Every number here is a
/// placeholder until a clinician weighs in; they are all adjustable in Settings.
public struct AlertSettings: Codable, Equatable, Sendable {
    /// Oxygen below this percentage counts as low.
    public var lowSpO2Threshold: Int
    /// Oxygen must stay low for this many seconds in a row before a check-in.
    public var lowSpO2Duration: TimeInterval
    /// No valid reading for this many seconds counts as signal lost.
    public var signalLossTimeout: TimeInterval
    /// Readings with a perfusion index below this (percent) are skipped as weak.
    public var minimumPerfusionIndex: Double
    /// Seconds the person has to tap "I'm OK" before contacts are texted.
    public var checkInCountdown: TimeInterval
    /// How long before a timed session ends to remind the person.
    public var endingSoonWarning: TimeInterval

    public init(
        lowSpO2Threshold: Int = 90,
        lowSpO2Duration: TimeInterval = 20,
        signalLossTimeout: TimeInterval = 15,
        minimumPerfusionIndex: Double = 0.3,
        checkInCountdown: TimeInterval = 30,
        endingSoonWarning: TimeInterval = 10 * 60
    ) {
        self.lowSpO2Threshold = lowSpO2Threshold
        self.lowSpO2Duration = lowSpO2Duration
        self.signalLossTimeout = signalLossTimeout
        self.minimumPerfusionIndex = minimumPerfusionIndex
        self.checkInCountdown = checkInCountdown
        self.endingSoonWarning = endingSoonWarning
    }

    public static let `default` = AlertSettings()

    /// Settings limits. Anything outside these is pulled back in, so a typo in
    /// Settings can never turn monitoring off.
    public static let thresholdRange = 80...95
    public static let lowDurationRange: ClosedRange<TimeInterval> = 10...60
    public static let signalLossRange: ClosedRange<TimeInterval> = 10...60
    public static let perfusionRange: ClosedRange<Double> = 0...2
    public static let countdownRange: ClosedRange<TimeInterval> = 15...120

    public func clamped() -> AlertSettings {
        var copy = self
        copy.lowSpO2Threshold = min(max(lowSpO2Threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        copy.lowSpO2Duration = lowSpO2Duration.clamped(to: Self.lowDurationRange)
        copy.signalLossTimeout = signalLossTimeout.clamped(to: Self.signalLossRange)
        copy.minimumPerfusionIndex = minimumPerfusionIndex.clamped(to: Self.perfusionRange)
        copy.checkInCountdown = checkInCountdown.clamped(to: Self.countdownRange)
        copy.endingSoonWarning = max(0, endingSoonWarning)
        return copy
    }
}

/// Why a check-in (and maybe an alert) started.
public enum TriggerReason: String, Codable, Equatable, Sendable {
    case lowOxygen
    case signalLost
}

public enum EngineState: Equatable, Sendable {
    case idle
    case monitoring
    case checkIn(reason: TriggerReason, deadline: Date)
    case alerted(reason: TriggerReason, at: Date)
    case ended
}

/// Things the rest of the app must act on. The engine itself never makes noise
/// or sends texts; `SessionManager` turns these into alarms and server calls.
public enum EngineEvent: Equatable, Sendable {
    case checkInStarted(reason: TriggerReason, deadline: Date)
    case checkInCleared
    case alertTriggered(reason: TriggerReason)
    case sessionEndingSoon(endsAt: Date)
    case sessionExpired
}

/// Decides when to check in and when to alert. Plain Swift with injected time,
/// so every rule is covered by unit tests that feed in fake readings.
///
/// The rule for every unclear case: when the engine can't tell whether the
/// person is OK, it checks in, and if nobody answers, it alerts.
public struct AlertEngine: Sendable {
    public private(set) var settings: AlertSettings
    public private(set) var state: EngineState = .idle
    public private(set) var startedAt: Date?
    public private(set) var endsAt: Date?
    /// The most recent reading of any quality, for the monitoring screen.
    public private(set) var lastReading: PulseReading?
    public private(set) var lastReadingQuality: ReadingQuality?
    /// When the last valid reading arrived (or when the window was last reset).
    public private(set) var lastValidAt: Date?
    /// Start of the current run of low oxygen readings, if one is in progress.
    public private(set) var lowStreakStartedAt: Date?
    /// How many weak or empty readings in a row, for the "weak signal" hint.
    public private(set) var consecutiveUnusableReadings = 0
    private var endingSoonSent = false

    public init(settings: AlertSettings = .default) {
        self.settings = settings.clamped()
    }

    public var isActive: Bool {
        switch state {
        case .monitoring, .checkIn, .alerted: return true
        case .idle, .ended: return false
        }
    }

    // MARK: - Inputs

    /// Starts monitoring. Call only after the sensor is connected and reading.
    public mutating func start(at now: Date, duration: TimeInterval? = nil) {
        state = .monitoring
        startedAt = now
        endsAt = duration.map { now.addingTimeInterval($0) }
        lastValidAt = now
        lowStreakStartedAt = nil
        consecutiveUnusableReadings = 0
        endingSoonSent = false
    }

    /// Puts a resumed session straight back into the alerted state, for when iOS
    /// relaunches the app after an alert already went out.
    public mutating func restoreAlerted(reason: TriggerReason, at now: Date) {
        if !isActive { start(at: now) }
        state = .alerted(reason: reason, at: now)
    }

    public mutating func updateSettings(_ newSettings: AlertSettings) {
        settings = newSettings.clamped()
    }

    @discardableResult
    public mutating func ingest(_ reading: PulseReading, at now: Date) -> [EngineEvent] {
        guard isActive else { return [] }
        let quality = reading.quality(minimumPerfusionIndex: settings.minimumPerfusionIndex)
        lastReading = reading
        lastReadingQuality = quality

        if quality == .valid, let spo2 = reading.spo2 {
            consecutiveUnusableReadings = 0
            lastValidAt = now
            if spo2 < settings.lowSpO2Threshold {
                if lowStreakStartedAt == nil { lowStreakStartedAt = now }
            } else {
                lowStreakStartedAt = nil
            }
        } else {
            // Weak or empty readings neither confirm nor clear a low streak. If they
            // go on long enough, the signal-lost rule below takes over.
            consecutiveUnusableReadings += 1
        }
        return evaluate(at: now)
    }

    /// Call about once a second, and whenever the app wakes up, so time-based
    /// rules fire even when no readings arrive.
    @discardableResult
    public mutating func tick(at now: Date) -> [EngineEvent] {
        evaluate(at: now)
    }

    /// The person tapped "I'm OK". Monitoring resumes with fresh windows, so a
    /// condition that is still there will start a new check-in on its own.
    @discardableResult
    public mutating func confirmOK(at now: Date) -> [EngineEvent] {
        guard case .checkIn = state else { return [] }
        state = .monitoring
        lastValidAt = now
        lowStreakStartedAt = nil
        consecutiveUnusableReadings = 0
        return [.checkInCleared]
    }

    /// The person ended the session (or tapped "I'm safe now" after an alert).
    public mutating func end() {
        state = .ended
    }

    // MARK: - Queries

    public func secondsUntilDeadline(at now: Date) -> TimeInterval? {
        guard case let .checkIn(_, deadline) = state else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    public func secondsSinceValidReading(at now: Date) -> TimeInterval? {
        lastValidAt.map { now.timeIntervalSince($0) }
    }

    // MARK: - Rules

    private mutating func evaluate(at now: Date) -> [EngineEvent] {
        switch state {
        case .idle, .ended, .alerted:
            // Once an alert has gone out the alarm keeps sounding and the server
            // handles the follow-up text, until the person ends the session.
            return []

        case let .checkIn(reason, deadline):
            if now >= deadline {
                state = .alerted(reason: reason, at: now)
                return [.alertTriggered(reason: reason)]
            }
            return []

        case .monitoring:
            if let lowStart = lowStreakStartedAt, now.timeIntervalSince(lowStart) >= settings.lowSpO2Duration {
                return startCheckIn(.lowOxygen, at: now)
            }
            if let lastValidAt, now.timeIntervalSince(lastValidAt) >= settings.signalLossTimeout {
                return startCheckIn(.signalLost, at: now)
            }
            return sessionTimerEvents(at: now)
        }
    }

    private mutating func startCheckIn(_ reason: TriggerReason, at now: Date) -> [EngineEvent] {
        let deadline = now.addingTimeInterval(settings.checkInCountdown)
        state = .checkIn(reason: reason, deadline: deadline)
        return [.checkInStarted(reason: reason, deadline: deadline)]
    }

    /// Timed sessions only end from plain monitoring, never in the middle of a
    /// check-in or after an alert.
    private mutating func sessionTimerEvents(at now: Date) -> [EngineEvent] {
        guard let endsAt else { return [] }
        if now >= endsAt {
            state = .ended
            return [.sessionExpired]
        }
        if !endingSoonSent, settings.endingSoonWarning > 0,
           now >= endsAt.addingTimeInterval(-settings.endingSoonWarning),
           let startedAt, endsAt.timeIntervalSince(startedAt) > settings.endingSoonWarning {
            endingSoonSent = true
            return [.sessionEndingSoon(endsAt: endsAt)]
        }
        return []
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
