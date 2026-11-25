import Combine
import Foundation
import UserNotifications

/// Local notifications are the alarm's backup for when the app is in the
/// background, and the only alarm if iOS has suspended or killed the app.
///
/// With the Critical Alerts entitlement (and the person's opt-in) they sound
/// even on silent and in Focus. Until Apple approves it, they are time-sensitive,
/// which breaks through Focus but not the silent switch.
final class NotificationService: NSObject, ObservableObject {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var criticalAlertsEnabled = false
    @Published private(set) var timeSensitiveEnabled = false

    private let center = UNUserNotificationCenter.current()

    private enum ID {
        static let checkInPrefix = "checkin-"
        static let alertSent = "alert-sent"
        static let deadman = "deadman"
        static let endingSoon = "ending-soon"
        static let alarmRepeatPrefix = "alarm-"
    }

    override init() {
        super.init()
        refresh()
    }

    var isAllowed: Bool { authorization == .authorized || authorization == .provisional }

    func requestPermission() async {
        // Asking for .criticalAlert is harmless before the entitlement exists; iOS ignores it.
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
        refresh()
    }

    func refresh() {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.authorization = settings.authorizationStatus
                self.criticalAlertsEnabled = settings.criticalAlertSetting == .enabled
                self.timeSensitiveEnabled = settings.timeSensitiveSetting == .enabled
            }
        }
    }

    // MARK: - Session notifications

    /// A burst of loud notifications through the check-in countdown, in case the
    /// app can't play its own alarm.
    func scheduleCheckIn(deadline: Date) {
        cancelCheckIn()
        let now = Date()
        var offset: TimeInterval = 0.5
        var index = 0
        while now.addingTimeInterval(offset) < deadline, index < 12 {
            let secondsLeft = Int(deadline.timeIntervalSince(now.addingTimeInterval(offset)).rounded())
            schedule(
                id: ID.checkInPrefix + String(index),
                title: "Are you OK?",
                body: "Open Spotter and tap I'm OK. Your contacts will be texted in \(secondsLeft) seconds.",
                after: offset,
                urgent: true
            )
            offset += 5
            index += 1
        }
    }

    func cancelCheckIn() {
        let ids = (0..<12).map { ID.checkInPrefix + String($0) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// After an alert, keep notifying loudly every 20 seconds for 4 minutes, so
    /// the phone stays noisy even if iOS suspends the app.
    func scheduleAlertSent() {
        cancelCheckIn()
        schedule(id: ID.alertSent, title: "Your contacts were texted", body: "They have your location. Open Spotter and tap I'm safe now if you're OK.", after: 0.5, urgent: true)
        for index in 0..<12 {
            schedule(id: ID.alarmRepeatPrefix + String(index), title: "Spotter alarm", body: "Contacts were texted. Open Spotter if you're OK.", after: TimeInterval(20 * (index + 1)), urgent: true)
        }
    }

    /// Rescheduled with every heartbeat. If the app stops running (swiped away,
    /// crashed), this fires and tells the person monitoring has stopped. The
    /// server's lost-contact text follows about a minute later.
    func refreshDeadman(after seconds: TimeInterval = 60) {
        schedule(
            id: ID.deadman,
            title: "Spotter stopped watching",
            body: "Monitoring isn't running. Open Spotter to start it again. Your contacts will be told the app lost contact.",
            after: seconds,
            urgent: true
        )
    }

    func scheduleEndingSoon(endsAt: Date) {
        schedule(id: ID.endingSoon, title: "Session ends soon", body: "Your Spotter session ends at \(Self.time(endsAt)). Start a new one if you still need it.", after: 1, urgent: false)
    }

    func cancelAllSessionNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: - Helpers

    private func schedule(id: String, title: String, body: String, after seconds: TimeInterval, urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if urgent {
            if criticalAlertsEnabled {
                content.interruptionLevel = .critical
                content.sound = .defaultCriticalSound(withAudioVolume: 1.0)
            } else {
                content.interruptionLevel = .timeSensitive
                content.sound = .defaultCritical
            }
        } else {
            content.interruptionLevel = .active
            content.sound = .default
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.5, seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Whether to show a notification while the app is open. Check-in and alarm
    /// notifications are hidden then, because the full-screen alarm is showing.
    static func shouldPresentInForeground(_ id: String) -> Bool {
        !(id.hasPrefix(ID.checkInPrefix) || id.hasPrefix(ID.alarmRepeatPrefix) || id == ID.alertSent || id == ID.deadman)
    }
}
