import Combine
import CoreLocation
import Foundation
import SafetyCore
import UIKit

/// Runs a session: feeds readings into the `AlertEngine` and turns its events
/// into alarms, notifications and server calls.
///
/// Layers of protection, from the phone outward:
/// 1. The app's own alarm (siren plus vibration) during a check-in and after an alert.
/// 2. Loud local notifications, which still fire if iOS suspends or kills the app.
/// 3. The server: it alerts on its own if a check-in deadline passes with no
///    answer, follows up after 5 minutes, and texts "lost contact" if heartbeats stop.
final class SessionManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for the oximeter to send a steady reading before monitoring starts.
        case starting(String)
        case monitoring
        case checkIn(reason: TriggerReason, deadline: Date)
        case alerted(reason: TriggerReason)
        case finished(Summary)
    }

    struct Summary: Equatable {
        var duration: TimeInterval
        var alertWentOut: Bool
        var safeTextSent: Bool
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startError: String?
    /// Ticks once a second so the UI can show elapsed time and countdowns.
    @Published private(set) var now = Date()
    /// True once the server has accepted this session (texts can go out).
    @Published private(set) var serverSessionReady = false
    @Published private(set) var lastServerContact: Date?
    @Published private(set) var queuedRequests = 0

    private(set) var engine = AlertEngine()

    private let store: AppStore
    private let hub: SensorHub
    private let alarm: AlarmController
    private let notifications: NotificationService
    private let location: LocationService
    private let server: ServerClient
    private let battery: BatteryMonitor

    private var ticker: Timer?
    private var startTimeout: Timer?
    private var pendingDuration: TimeInterval?
    private var lastHeartbeatAt = Date.distantPast
    private var lastCreateAttemptAt = Date.distantPast
    private var creatingServerSession = false
    private var flushing = false
    private var observers: [NSObjectProtocol] = []

    private static let sessionPlaceholder = "{session}"
    private static let heartbeatInterval: TimeInterval = 20
    private static let startTimeoutSeconds: TimeInterval = 45
    private static let sensorUser = "session"

    init(store: AppStore, hub: SensorHub, alarm: AlarmController, notifications: NotificationService, location: LocationService, server: ServerClient, battery: BatteryMonitor) {
        self.store = store
        self.hub = hub
        self.alarm = alarm
        self.notifications = notifications
        self.location = location
        self.server = server
        self.battery = battery

        hub.onReading = { [weak self] reading in self?.handleReading(reading) }
        hub.onConnectionChange = { [weak self] _ in self?.tick() }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        })
        queuedRequests = store.data.outbox.entries.count
    }

    var isRunning: Bool {
        switch phase {
        case .starting, .monitoring, .checkIn, .alerted: return true
        case .idle, .finished: return false
        }
    }

    var startedAt: Date? { store.data.activeSession?.startedAt }
    var endsAt: Date? { store.data.activeSession?.endsAt }

    // MARK: - Start

    func start(duration: TimeInterval?) {
        guard !isRunning else { return }
        guard hub.sensor != nil else {
            startError = "Pair your oximeter first (Settings > Oximeter)."
            return
        }
        startError = nil
        pendingDuration = duration
        phase = .starting("Connecting to your oximeter…")

        // These must start while the app is in the foreground.
        alarm.arm()
        location.startSession()
        hub.acquire(Self.sensorUser)

        startTimeout?.invalidate()
        startTimeout = Timer.scheduledTimer(withTimeInterval: Self.startTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.abortStart("The oximeter isn't sending a steady reading. Check that it's turned on and snug on your finger, then try again.")
        }
    }

    func cancelStart() {
        guard case .starting = phase else { return }
        abortStart(nil)
    }

    private func abortStart(_ message: String?) {
        startTimeout?.invalidate()
        startTimeout = nil
        hub.release(Self.sensorUser)
        location.stopSession()
        alarm.disarm()
        phase = .idle
        startError = message
    }

    private func beginMonitoring() {
        startTimeout?.invalidate()
        startTimeout = nil
        let now = Date()
        engine = AlertEngine(settings: store.data.alertSettings)
        engine.start(at: now, duration: pendingDuration)
        store.data.activeSession = ActiveSession(startedAt: now, endsAt: engine.endsAt)
        serverSessionReady = false
        lastHeartbeatAt = .distantPast
        lastCreateAttemptAt = .distantPast
        phase = .monitoring
        (hub.sensor as? FakePulseSensor)?.restartScenario()
        notifications.refreshDeadman()
        startTicker()
        createServerSessionIfNeeded()
    }

    /// Picks a session back up after iOS relaunched the app (Bluetooth state
    /// restoration, a crash, or the person opening it again after swiping it away).
    func resumeIfNeeded() {
        guard !isRunning, let active = store.data.activeSession else { return }
        let now = Date()
        if let endsAt = active.endsAt, endsAt <= now, active.alertReason == nil {
            // The timer ran out while the app wasn't running.
            if active.serverSessionID != nil { enqueue("end", [:]) }
            store.data.activeSession = nil
            flushOutbox()
            return
        }

        alarm.arm()
        location.startSession()
        hub.acquire(Self.sensorUser)
        engine = AlertEngine(settings: store.data.alertSettings)
        engine.start(at: now, duration: active.endsAt.map { $0.timeIntervalSince(now) })
        serverSessionReady = active.serverSessionID != nil

        if let reason = active.alertReason {
            engine.restoreAlerted(reason: reason, at: now)
            phase = .alerted(reason: reason)
            alarm.set(.alert)
        } else {
            phase = .monitoring
        }
        notifications.refreshDeadman()
        startTicker()
        // Heartbeat right away: if the server already told contacts the app
        // lost contact, this tells them it's back.
        lastHeartbeatAt = .distantPast
        tick()
    }

    // MARK: - Person's actions

    func confirmOK() {
        handle(engine.confirmOK(at: Date()))
    }

    /// "I'm safe now" after an alert: texts contacts and ends the session.
    func markSafe() {
        enqueue("safe", [:])
        finish(safeTextSent: true)
    }

    func endSession() {
        enqueue("end", [:])
        finish(safeTextSent: false)
    }

    func dismissSummary() {
        if case .finished = phase { phase = .idle }
    }

    // MARK: - Engine plumbing

    private func handleReading(_ reading: PulseReading) {
        if case .starting = phase {
            if reading.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex) == .valid {
                beginMonitoring()
            } else {
                phase = .starting("Waiting for a steady reading. Keep your hand still.")
            }
            return
        }
        guard engine.isActive else { return }
        handle(engine.ingest(reading, at: Date()))
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        now = Date()
        guard engine.isActive else { return }
        handle(engine.tick(at: now))
        guard isRunning else { return }

        if now.timeIntervalSince(lastHeartbeatAt) >= Self.heartbeatInterval {
            lastHeartbeatAt = now
            sendHeartbeat()
            notifications.refreshDeadman()
        }
        createServerSessionIfNeeded()
        flushOutbox()
        checkPhoneBattery()
    }

    private func handle(_ events: [EngineEvent]) {
        for event in events {
            switch event {
            case let .checkInStarted(reason, deadline):
                phase = .checkIn(reason: reason, deadline: deadline)
                alarm.set(.checkIn)
                notifications.scheduleCheckIn(deadline: deadline)
                enqueue("check-in", ["reason": reason.rawValue, "deadline": Int(deadline.timeIntervalSince1970 * 1000)])

            case .checkInCleared:
                phase = .monitoring
                alarm.set(.off)
                notifications.cancelCheckIn()
                enqueue("check-in/clear", [:])

            case let .alertTriggered(reason):
                phase = .alerted(reason: reason)
                alarm.set(.alert)
                notifications.scheduleAlertSent()
                store.data.activeSession?.alertReason = reason
                enqueue("alert", ["reason": reason.rawValue])

            case let .sessionEndingSoon(endsAt):
                notifications.scheduleEndingSoon(endsAt: endsAt)

            case .sessionExpired:
                enqueue("end", [:])
                finish(safeTextSent: false)
            }
        }
        if !events.isEmpty { flushOutbox() }
    }

    private func finish(safeTextSent: Bool) {
        let active = store.data.activeSession
        engine.end()
        ticker?.invalidate()
        ticker = nil
        startTimeout?.invalidate()
        hub.release(Self.sensorUser)
        location.stopSession()
        alarm.disarm()
        notifications.cancelAllSessionNotifications()

        // Anything queued before the server session existed can't be sent now.
        if active?.serverSessionID == nil {
            store.data.outbox.removeUnresolved(placeholder: Self.sessionPlaceholder)
        }
        store.data.activeSession = nil
        serverSessionReady = false
        phase = .finished(Summary(
            duration: active.map { Date().timeIntervalSince($0.startedAt) } ?? 0,
            alertWentOut: active?.alertReason != nil,
            safeTextSent: safeTextSent
        ))
        flushOutbox()
    }

    // MARK: - Server

    private var locationJSON: [String: Any]? {
        location.forAlert.map(ServerClient.json)
    }

    /// Queues a session request. Uses the real session path if the server
    /// session exists, otherwise a placeholder filled in once it does.
    private func enqueue(_ route: String, _ fields: [String: Any]) {
        var body = fields
        if let locationJSON { body["location"] = locationJSON }
        let active = store.data.activeSession
        let sessionID = active?.serverSessionID ?? Self.sessionPlaceholder
        store.data.outbox.enqueue(
            path: "v1/sessions/\(sessionID)/\(route)",
            body: ServerClient.encode(body),
            token: active?.serverToken,
            at: Date()
        )
        queuedRequests = store.data.outbox.entries.count
    }

    private func createServerSessionIfNeeded() {
        guard server.isConfigured, !creatingServerSession,
              let active = store.data.activeSession, active.serverSessionID == nil,
              Date().timeIntervalSince(lastCreateAttemptAt) >= 10 else { return }
        creatingServerSession = true
        lastCreateAttemptAt = Date()
        let data = store.data
        let remaining = active.endsAt.map { $0.timeIntervalSinceNow }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.creatingServerSession = false }
            do {
                let created = try await self.server.createSession(firstName: data.firstName, contacts: data.contacts, plannedDuration: remaining, location: self.location.forAlert)
                // The session may have ended while the request was in flight.
                guard self.store.data.activeSession?.startedAt == active.startedAt else {
                    self.store.data.outbox.enqueue(path: "v1/sessions/\(created.id)/end", body: Data("{}".utf8), token: created.token, at: Date())
                    self.flushOutbox()
                    return
                }
                self.store.data.activeSession?.serverSessionID = created.id
                self.store.data.activeSession?.serverToken = created.token
                self.store.data.outbox.resolve(placeholder: Self.sessionPlaceholder, with: created.id, token: created.token)
                self.serverSessionReady = true
                self.lastServerContact = Date()
                self.flushOutbox()
            } catch {
                NSLog("Spotter: could not start server session: \(error.localizedDescription)")
            }
        }
    }

    private func sendHeartbeat() {
        guard let active = store.data.activeSession, let id = active.serverSessionID, let token = active.serverToken else { return }
        var body: [String: Any] = [:]
        if let locationJSON { body["location"] = locationJSON }
        let payload = ServerClient.encode(body)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.server.send(path: "v1/sessions/\(id)/heartbeat", body: payload, token: token)
                self.lastServerContact = Date()
            } catch let error as ServerClient.ServerError {
                if case .http(404, _) = error, self.store.data.activeSession?.serverSessionID == id {
                    // The server forgot the session (it outlived its maximum length). Start a fresh one.
                    self.store.data.activeSession?.serverSessionID = nil
                    self.store.data.activeSession?.serverToken = nil
                    self.serverSessionReady = false
                }
            } catch {
                // Offline; the next heartbeat will try again.
            }
        }
    }

    /// Sends queued requests in order. Stops at the first network failure so
    /// texts never arrive out of order.
    private func flushOutbox() {
        guard !flushing, server.isConfigured else { return }
        flushing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.flushing = false
                self.queuedRequests = self.store.data.outbox.entries.count
            }
            let due = self.store.data.outbox.due(at: Date())
            for entry in due where !entry.path.contains(Self.sessionPlaceholder) {
                do {
                    try await self.server.send(path: entry.path, body: entry.body, token: entry.token)
                    self.store.data.outbox.markSent(entry.id)
                    self.lastServerContact = Date()
                } catch let error as ServerClient.ServerError where error.isPermanent {
                    NSLog("Spotter: server rejected \(entry.path): \(error.localizedDescription)")
                    self.store.data.outbox.markSent(entry.id)
                } catch {
                    self.store.data.outbox.markFailed(entry.id, at: Date())
                    break
                }
            }
        }
    }

    private func checkPhoneBattery() {
        guard battery.isAboutToDie, let active = store.data.activeSession, !active.lowBatterySent else { return }
        store.data.activeSession?.lowBatterySent = true
        enqueue("low-battery", [:])
        flushOutbox()
    }
}
