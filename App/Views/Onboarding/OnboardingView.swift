import SafetyCore
import SwiftUI

/// One-time setup: name, oximeter, contacts, permissions, test text.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, pair, contacts, permissions, test
    }

    @EnvironmentObject private var store: AppStore
    @State private var step: Step = .welcome

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StepProgress(current: step.rawValue, total: Step.allCases.count)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                Group {
                    switch step {
                    case .welcome: WelcomeStep(next: advance)
                    case .pair: PairStep(next: advance)
                    case .contacts: ContactsStep(next: advance)
                    case .permissions: PermissionsStep(next: advance)
                    case .test: TestAlertStep(next: finish)
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func advance() {
        withAnimation(.easeInOut) { step = Step(rawValue: step.rawValue + 1) ?? .test }
    }

    private func finish() {
        withAnimation { store.data.onboardingComplete = true }
    }
}

/// Segmented progress bar across the top of setup.
private struct StepProgress: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Theme.accent : Color.secondary.opacity(0.2))
                    .frame(height: 5)
            }
        }
        .animation(.easeInOut, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}

/// Shared layout: icon, title, subtitle, content, and a pinned main button.
private struct StepScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    var buttonEnabled = true
    var footnote: String? = nil
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IconBadge(systemName: symbol, size: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                BigButton(title: buttonTitle, action: action)
                    .disabled(!buttonEnabled)
                if let footnote {
                    Text(footnote).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.bar)
        }
    }
}

private struct WelcomeStep: View {
    @EnvironmentObject private var store: AppStore
    let next: () -> Void

    var body: some View {
        StepScaffold(
            symbol: "dot.radiowaves.left.and.right",
            title: "A spotter for when you use alone",
            subtitle: "Takes about five minutes to set up. No account needed.",
            buttonTitle: "Get started",
            buttonEnabled: !store.data.firstName.trimmingCharacters(in: .whitespaces).isEmpty,
            action: next
        ) {
            VStack(alignment: .leading, spacing: 16) {
                feature("sensor.fill", "Watches your oxygen", "Through a Bluetooth fingertip oximeter.")
                feature("bell.badge.fill", "Checks in loudly", "If something looks wrong, an alarm asks if you're OK.")
                feature("message.fill", "Texts your people", "No answer in 30 seconds? Your contacts get your location.")
            }
            .card()

            VStack(alignment: .leading, spacing: 8) {
                Text("Your first name").font(.headline)
                TextField("First name", text: $store.data.firstName)
                    .textContentType(.givenName)
                    .font(.title3)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .submitLabel(.continue)
                    .onSubmit { if !store.data.firstName.isEmpty { next() } }
                Text("Only used in texts to your contacts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Label("Spotter is a backup, not a guarantee. Phones die and sensors slip.", systemImage: "hand.raised.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(systemName: symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PairStep: View {
    let next: () -> Void
    var body: some View {
        PairSensorView(onDone: next)
    }
}

private struct ContactsStep: View {
    @EnvironmentObject private var store: AppStore
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                IconBadge(systemName: "person.2.fill", size: 56)
                Text("Who should we text?")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("One to three people who can get to you quickly.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            ContactsEditor(header: nil)
        }
        .safeAreaInset(edge: .bottom) {
            BigButton(title: "Continue", action: next)
                .disabled(store.data.contacts.isEmpty)
                .padding()
                .background(.bar)
        }
    }
}

private struct PermissionsStep: View {
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var location: LocationService
    let next: () -> Void

    var body: some View {
        StepScaffold(
            symbol: "lock.shield.fill",
            title: "Two permissions",
            subtitle: "So Spotter keeps working with your screen locked.",
            buttonTitle: "Continue",
            action: next
        ) {
            VStack(spacing: 12) {
                PermissionRow(
                    symbol: "bell.badge.fill",
                    title: "Notifications",
                    detail: "So the alarm reaches you when Spotter is in the background. Allow Critical Alerts if asked: they sound even on silent.",
                    granted: notifications.isAllowed
                ) {
                    Task { await notifications.requestPermission() }
                }
                PermissionRow(
                    symbol: "location.fill",
                    title: "Location",
                    detail: "So an alert can say where you are. Only used during a session.",
                    granted: location.isAllowed
                ) {
                    location.requestPermission()
                }
                if notifications.isAllowed, !notifications.timeSensitiveEnabled, !notifications.criticalAlertsEnabled {
                    WarningRow(text: "Turn on Time Sensitive in Settings > Notifications > Spotter so alarms break through Focus.")
                        .card()
                }
            }
        }
        .onAppear { notifications.refresh() }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(systemName: granted ? "checkmark" : symbol, tint: granted ? Theme.good : Theme.accent, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if granted {
                    Text("Allowed").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.good)
                } else {
                    Button("Allow", action: request)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .card()
        .animation(.default, value: granted)
    }
}

private struct TestAlertStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                IconBadge(systemName: "paperplane.fill", size: 56)
                Text("Send a test")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Catches wrong numbers before you rely on Spotter.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            TestAlertPanel()
        }
        .safeAreaInset(edge: .bottom) {
            BigButton(title: "Finish setup", systemImage: "checkmark", action: next)
                .padding()
                .background(.bar)
        }
    }
}
