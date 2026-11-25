import Combine
import Foundation
import SafetyCore

/// Everything the app remembers. Lives only on this phone, in one JSON file.
/// Nothing here says what the person was doing; there is no session history.
struct AppData: Codable, Equatable {
    var firstName: String = ""
    var contacts: [EmergencyContact] = []
    var alertSettings: AlertSettings = .default
    var pairedSensorID: UUID?
    var pairedSensorName: String?
    var onboardingComplete = false
    /// Session length picked last time, in seconds. `nil` means no time limit.
    var defaultDuration: TimeInterval?
    /// Developer option: drive the app with a scripted sensor instead of Bluetooth.
    var useFakeSensor = false
    var fakeScenario: SensorScenario = .normal
    /// Set while a session is running, so it resumes if iOS relaunches the app.
    var activeSession: ActiveSession?
    /// Server requests waiting for a connection.
    var outbox = Outbox()

    init() {}

    // Tolerate missing keys so adding a field never wipes someone's contacts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppData()
        firstName = try c.decodeIfPresent(String.self, forKey: .firstName) ?? defaults.firstName
        contacts = try c.decodeIfPresent([EmergencyContact].self, forKey: .contacts) ?? defaults.contacts
        alertSettings = try c.decodeIfPresent(AlertSettings.self, forKey: .alertSettings) ?? defaults.alertSettings
        pairedSensorID = try c.decodeIfPresent(UUID.self, forKey: .pairedSensorID)
        pairedSensorName = try c.decodeIfPresent(String.self, forKey: .pairedSensorName)
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        defaultDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .defaultDuration)
        useFakeSensor = try c.decodeIfPresent(Bool.self, forKey: .useFakeSensor) ?? false
        fakeScenario = try c.decodeIfPresent(SensorScenario.self, forKey: .fakeScenario) ?? .normal
        activeSession = try c.decodeIfPresent(ActiveSession.self, forKey: .activeSession)
        outbox = try c.decodeIfPresent(Outbox.self, forKey: .outbox) ?? Outbox()
    }
}

struct ActiveSession: Codable, Equatable {
    var startedAt: Date
    var endsAt: Date?
    var serverSessionID: String?
    var serverToken: String?
    /// Set once an alert went out, so a relaunch goes straight back to the alarm.
    var alertReason: TriggerReason?
    var lowBatterySent = false
}

/// Loads and saves `AppData`. Writes are atomic and the file stays readable
/// after first unlock, so a session can keep running with the screen locked.
final class AppStore: ObservableObject {
    @Published var data: AppData {
        didSet { if data != oldValue { save() } }
    }

    private let url: URL

    init(fileName: String = "appdata.json") {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = folder.appendingPathComponent(fileName)
        if let bytes = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(AppData.self, from: bytes) {
            data = decoded
        } else {
            data = AppData()
        }
    }

    private func save() {
        do {
            let bytes = try JSONEncoder().encode(data)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            NSLog("Spotter: could not save settings: \(error.localizedDescription)")
        }
    }

    /// Wipes everything on this phone (Settings > Erase all data).
    func eraseAll() {
        data = AppData()
    }
}
