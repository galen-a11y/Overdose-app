import SafetyCore
import SwiftUI

/// One-time setup, one question per screen.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, name, oximeter, contacts, permissions, test, done
    }

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var hub: SensorHub
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var location: LocationService
    @State private var step: Step = .welcome
    @State private var testSent = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch step {
                case .welcome: welcome
                case .name: name
                case .oximeter: oximeter
                case .contacts: contacts
                case .permissions: permissions
                case .test: test
                case .done: done
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: - Steps

    private var welcome: some View {
        SetupPage(
            title: "Spotter",
            subtitle: "Watches your oxygen while you use. Texts your people if you don't respond.",
            button: "Set up",
            action: next
        ) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 80, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    private var name: some View {
        SetupPage(
            title: "What's your first name?",
            subtitle: "Used in texts to your contacts.",
            button: "Continue",
            enabled: !store.data.firstName.trimmingCharacters(in: .whitespaces).isEmpty,
            action: next
        ) {
            TextField("First name", text: $store.data.firstName)
                .textContentType(.givenName)
                .font(.title2)
                .submitLabel(.continue)
                .focused($nameFocused)
                .onSubmit { if !store.data.firstName.isEmpty { next() } }
                .fieldStyle()
                .onAppear { nameFocused = true }
        }
    }

    private var oximeter: some View {
        SetupPage(
            title: "Connect your oximeter",
            subtitle: "Put it on your finger to turn it on.",
            button: "Continue",
            enabled: sensorReading,
            secondary: store.data.pairedSensorID == nil && !store.data.useFakeSensor
                ? SecondaryAction(title: "Try without one") { store.data.useFakeSensor = true }
                : nil,
            action: next
        ) {
            OximeterPairing()
        }
    }

    private var contacts: some View {
        SetupPage(
            title: "Who should we text?",
            subtitle: "Up to 3 people who can get to you fast.",
            button: "Continue",
            enabled: !store.data.contacts.isEmpty,
            action: next
        ) {
            VStack(spacing: 10) {
                ForEach(store.data.contacts) { contact in
                    ContactRow(contact: contact) {
                        withAnimation { store.data.contacts.removeAll { $0.id == contact.id } }
                    }
                    .card(padding: 12)
                }
                if store.data.contacts.count < EmergencyContact.maximumCount {
                    AddContactForm()
                        .padding(.top, store.data.contacts.isEmpty ? 0 : 8)
                }
            }
        }
    }

    private var permissions: some View {
        SetupPage(
            title: "Allow alerts",
            subtitle: "So Spotter works with your screen locked.",
            button: "Continue",
            enabled: notifications.isAllowed,
            secondary: notifications.isAllowed ? nil : SecondaryAction(title: "Skip", action: next),
            action: next
        ) {
            VStack(spacing: 10) {
                PermissionButton(title: "Notifications", symbol: "bell.fill", granted: notifications.isAllowed) {
                    Task { await notifications.requestPermission() }
                }
                PermissionButton(title: "Location", symbol: "location.fill", granted: location.isAllowed) {
                    location.requestPermission()
                }
            }
        }
        .onAppear { notifications.refresh() }
    }

    private var test: some View {
        SetupPage(
            title: "Send a test text",
            subtitle: "Make sure it reaches them.",
            button: testSent ? "Continue" : "Skip for now",
            action: next
        ) {
            TestTextPanel(sent: $testSent)
        }
    }

    private var done: some View {
        SetupPage(
            title: "You're all set",
            subtitle: "Tap Start whenever you use.",
            button: "Done",
            action: { withAnimation { store.data.onboardingComplete = true } }
        ) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(Theme.good)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
            } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold))
            }
            .opacity(step == .welcome || step == .done ? 0 : 1)
            .disabled(step == .welcome || step == .done)
            .accessibilityLabel("Back")

            HStack(spacing: 5) {
                ForEach(1..<(Step.allCases.count - 1), id: \.self) { index in
                    Capsule()
                        .fill(index <= step.rawValue ? Theme.accent : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            .opacity(step == .welcome || step == .done ? 0 : 1)
            .accessibilityHidden(true)

            Color.clear.frame(width: 20, height: 1)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private var sensorReading: Bool {
        hub.latest?.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex) == .valid
    }

    private func next() {
        nameFocused = false
        withAnimation(.easeInOut(duration: 0.3)) { step = Step(rawValue: step.rawValue + 1) ?? .done }
    }
}

private struct SecondaryAction {
    let title: String
    let action: () -> Void
}

/// Title, one line of subtitle, content, and one main button at the bottom.
private struct SetupPage<Content: View>: View {
    let title: String
    let subtitle: String
    let button: String
    var enabled = true
    var secondary: SecondaryAction? = nil
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                BigButton(title: button, action: action)
                    .disabled(!enabled)
                if let secondary {
                    Button(secondary.title, action: secondary.action)
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .padding(.top, 8)
            .background(Theme.background)
        }
    }
}

private struct PermissionButton: View {
    let title: String
    let symbol: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(systemName: granted ? "checkmark" : symbol, tint: granted ? Theme.good : Theme.accent, size: 44)
                Text(title).font(.headline)
                Spacer()
                Text(granted ? "On" : "Allow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(granted ? Theme.good : Theme.accent)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .disabled(granted)
        .animation(.default, value: granted)
    }
}
