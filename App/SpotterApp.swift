import Combine
import SwiftUI
import UserNotifications

@main
struct SpotterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env.store)
                .environmentObject(env.session)
                .environmentObject(env.hub)
                .environmentObject(env.alarm)
                .environmentObject(env.notifications)
                .environmentObject(env.location)
                .environmentObject(env.battery)
                .environmentObject(env.connectivity)
                .environment(\.server, env.server)
        }
    }
}

/// Builds every long-lived object once. Created at launch (from the app
/// delegate) so the Bluetooth central exists in time for state restoration.
final class AppEnvironment {
    static let shared = AppEnvironment()

    let store = AppStore()
    let hub = SensorHub()
    let alarm = AlarmController()
    let notifications = NotificationService()
    let location = LocationService()
    let battery = BatteryMonitor()
    let connectivity = ConnectivityMonitor()
    let server = ServerClient()
    let session: SessionManager
    private var cancellables = Set<AnyCancellable>()

    private struct SensorConfig: Equatable {
        var id: UUID?
        var name: String?
        var fake: Bool
        var scenario: String
    }

    private init() {
        session = SessionManager(store: store, hub: hub, alarm: alarm, notifications: notifications, location: location, server: server, battery: battery)
        hub.configure(with: store.data)

        // Rebuild the sensor when the person pairs a new one or toggles the fake sensor.
        store.$data
            .map { SensorConfig(id: $0.pairedSensorID, name: $0.pairedSensorName, fake: $0.useFakeSensor, scenario: $0.fakeScenario.rawValue) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.hub.configure(with: self.store.data) }
            }
            .store(in: &cancellables)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let env = AppEnvironment.shared
        env.session.resumeIfNeeded()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let id = notification.request.identifier
        completionHandler(NotificationService.shouldPresentInForeground(id) ? [.banner, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // Tapping any notification just opens the app, where the full-screen
        // check-in or alarm is waiting. There is deliberately no "I'm OK" button
        // on the lock screen, so it can't be tapped by accident.
        completionHandler()
    }
}

private struct ServerKey: EnvironmentKey {
    static let defaultValue = ServerClient()
}

extension EnvironmentValues {
    var server: ServerClient {
        get { self[ServerKey.self] }
        set { self[ServerKey.self] = newValue }
    }
}
