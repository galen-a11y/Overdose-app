import SafetyCore
import SwiftUI

/// One-time setup: name, oximeter, contacts, permissions, test alert.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, pair, contacts, permissions, test
    }

    @EnvironmentObject private var store: AppStore
    @State private var step: Step = .welcome

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: WelcomeStep(next: advance)
                case .pair: PairSensorView(onDone: advance)
                case .contacts: ContactsStep(next: advance)
                case .permissions: PermissionsStep(next: advance)
                case .test: TestAlertStep(next: finish)
                }
            }
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func advance() {
        withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .test }
    }

    private func finish() {
        store.data.onboardingComplete = true
    }
}

private struct WelcomeStep: View {
    @EnvironmentObject private var store: AppStore
    let next: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spotter watches your oximeter while you use alone.")
                    .font(.largeTitle.weight(.bold))
                Text("If your oxygen stays low or the signal goes quiet, it sounds a loud alarm. If you don't tap I'm OK, it texts your emergency contacts your location.")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 8) {
                    Text("It's a backup, not a guarantee.").font(.headline)
                    Text("Phones die, sensors slip, and texts can be delayed. If you can, also call Never Use Alone (800-484-3731) or have someone with you who has naloxone.")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your first name").font(.headline)
                    TextField("First name", text: $store.data.firstName)
                        .textContentType(.givenName)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .focused($nameFocused)
                    Text("Only used in texts to your contacts. No account, nothing else about you.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                BigButton(title: "Set up") { next() }
                    .disabled(store.data.firstName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }
}

private struct ContactsStep: View {
    @EnvironmentObject private var store: AppStore
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ContactsEditor(header: "Who should be texted if you don't respond? Add one to three people who can get to you quickly.")
            BigButton(title: "Continue") { next() }
                .disabled(store.data.contacts.isEmpty)
                .padding()
        }
        .navigationTitle("Emergency contacts")
    }
}

private struct PermissionsStep: View {
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var location: LocationService
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spotter needs two permissions to work with the screen locked.")
                    .font(.title3)

                PermissionRow(
                    title: "Notifications",
                    detail: "So the alarm can reach you when Spotter is in the background. If iOS asks about Critical Alerts, allow them: they sound even on silent.",
                    granted: notifications.isAllowed
                ) {
                    Task { await notifications.requestPermission() }
                }

                PermissionRow(
                    title: "Location",
                    detail: "So an alert can say where you are. It's only used during a session.",
                    granted: location.isAllowed
                ) {
                    location.requestPermission()
                }

                if !notifications.timeSensitiveEnabled, notifications.isAllowed, !notifications.criticalAlertsEnabled {
                    WarningRow(text: "Time Sensitive notifications are off. Turn them on in Settings > Notifications > Spotter so alarms break through Focus.")
                }

                BigButton(title: "Continue") { next() }
                    .padding(.top)
            }
            .padding()
        }
        .navigationTitle("Permissions")
        .onAppear { notifications.refresh() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if !granted {
                    Button("Allow \(title)", action: request)
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct TestAlertStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TestAlertPanel()
            BigButton(title: "Finish setup") { next() }
                .padding()
        }
        .navigationTitle("Test alert")
    }
}
