import SafetyCore
import SwiftUI

/// One-time setup in the style of Apple's Check In: one idea per screen.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, howItWorks, name, oximeter, contacts, permissions, test, done
    }

    @EnvironmentObject private var store: AppStore
    @State private var step: Step = .welcome

    var body: some View {
        ZStack {
            switch step {
            case .welcome: WelcomeStep(next: next)
            case .howItWorks: HowItWorksStep(next: next, back: back)
            case .name: NameStep(next: next, back: back)
            case .oximeter: OximeterStep(next: next, back: back)
            case .contacts: ContactsStep(next: next, back: back)
            case .permissions: PermissionsStep(next: next, back: back)
            case .test: TestStep(next: next, back: back)
            case .done: DoneStep { withAnimation { store.data.onboardingComplete = true } }
            }
        }
        .id(step)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
        .background(Theme.sheet.ignoresSafeArea())
    }

    private func next() {
        withAnimation(.easeInOut(duration: 0.3)) { step = Step(rawValue: step.rawValue + 1) ?? .done }
    }

    private func back() {
        withAnimation(.easeInOut(duration: 0.3)) { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        SheetPage(
            title: "Spotter has your back.",
            message: "It watches your oxygen while you use, and lets your people know if you don't respond.",
            primary: "Continue",
            onPrimary: next
        ) {
            ArtPanel(height: 380) {
                PhoneMock {
                    VStack(spacing: 14) {
                        OxygenRing(spo2: 97, threshold: 90, quality: .valid, size: 130, trackColor: .white.opacity(0.08))
                        StatusPill(text: "Watching", color: Theme.good, pulsing: true)
                    }
                }
            }
        } content: {
            EmptyView()
        }
    }
}

private struct HowItWorksStep: View {
    let next: () -> Void
    let back: () -> Void

    var body: some View {
        SheetPage(title: "Your contacts will be texted when…", primary: "Continue", onBack: back, onPrimary: next) {
            VStack(alignment: .leading, spacing: 28) {
                InfoRow(symbol: "lungs.fill", title: "Your oxygen stays low", detail: "You get a loud check-in first.")
                InfoRow(symbol: "waveform.path.ecg", title: "The signal goes quiet", detail: "Like the oximeter slipping off.")
                InfoRow(symbol: "clock.fill", title: "You don't respond", detail: "After 30 seconds, they get your location.")
                InfoRow(symbol: "antenna.radiowaves.left.and.right.slash", title: "Your phone goes offline", detail: "They get a heads-up to check on you.")
            }
            .padding(.top, 36)
        }
    }
}

private struct NameStep: View {
    @EnvironmentObject private var store: AppStore
    let next: () -> Void
    let back: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        SheetPage(
            title: "What's your first name?",
            message: "Only used in texts to your contacts.",
            primary: "Continue",
            primaryEnabled: !store.data.firstName.trimmingCharacters(in: .whitespaces).isEmpty,
            onBack: back,
            onPrimary: next
        ) {
            TextField("First name", text: $store.data.firstName)
                .textContentType(.givenName)
                .font(.system(size: 22))
                .submitLabel(.continue)
                .focused($focused)
                .onSubmit { if !store.data.firstName.isEmpty { next() } }
                .fieldStyle()
                .padding(.top, 40)
                .onAppear { focused = true }
        }
    }
}

private struct OximeterStep: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var hub: SensorHub
    @StateObject private var scanner = OximeterScanner()
    let next: () -> Void
    let back: () -> Void

    var body: some View {
        SheetPage(
            title: isPaired ? (isReading ? "You're connected." : "Almost there.") : "Connect your oximeter.",
            message: isPaired ? (isReading ? "Spotter can see your reading." : "Put it on your finger.") : "Put it on your finger to turn it on, then tap it below.",
            primary: "Continue",
            primaryEnabled: isReading,
            secondary: isPaired ? "Choose Another" : "Try Without One",
            onBack: back,
            onPrimary: next,
            onSecondary: {
                if isPaired {
                    store.data.pairedSensorID = nil
                    store.data.useFakeSensor = false
                } else {
                    store.data.useFakeSensor = true
                }
            }
        ) {
            ArtPanel(height: 300) {
                if isPaired {
                    OxygenRing(
                        spo2: hub.latest?.spo2,
                        threshold: store.data.alertSettings.lowSpO2Threshold,
                        quality: quality,
                        size: 190,
                        trackColor: .white.opacity(0.08)
                    )
                } else {
                    Image(systemName: "sensor.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
        } content: {
            if !isPaired {
                VStack(spacing: 12) {
                    if let problem = scanner.bluetoothProblem {
                        Text(problem).foregroundStyle(Theme.danger)
                    }
                    ForEach(scanner.visibleDevices) { device in
                        OptionCard(symbol: "sensor.fill", title: device.name, selected: false) { pair(device) }
                    }
                    if scanner.visibleDevices.isEmpty, scanner.bluetoothProblem == nil {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.secondaryText)
                            Text("Looking…").foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .animation(.default, value: isPaired)
        .animation(.default, value: isReading)
        .onAppear {
            scanner.start()
            hub.acquire("pairing")
        }
        .onDisappear {
            scanner.stop()
            hub.release("pairing")
        }
    }

    private var isPaired: Bool { store.data.pairedSensorID != nil || store.data.useFakeSensor }

    private var quality: ReadingQuality? {
        hub.latest?.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex)
    }

    private var isReading: Bool { isPaired && quality == .valid }

    private func pair(_ device: OximeterScanner.Device) {
        store.data.useFakeSensor = false
        store.data.pairedSensorID = device.id
        store.data.pairedSensorName = device.name
        DispatchQueue.main.async { hub.acquire("pairing") }
    }
}

private struct ContactsStep: View {
    @EnvironmentObject private var store: AppStore
    let next: () -> Void
    let back: () -> Void

    var body: some View {
        SheetPage(
            title: "Who should we text?",
            message: "Up to 3 people who can get to you fast.",
            primary: "Continue",
            primaryEnabled: !store.data.contacts.isEmpty,
            onBack: back,
            onPrimary: next
        ) {
            VStack(spacing: 12) {
                ForEach(store.data.contacts) { contact in
                    ContactRow(contact: contact) {
                        withAnimation { store.data.contacts.removeAll { $0.id == contact.id } }
                    }
                    .padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                if store.data.contacts.count < EmergencyContact.maximumCount {
                    AddContactForm()
                }
            }
            .padding(.top, 12)
        }
    }
}

private struct PermissionsStep: View {
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var location: LocationService
    let next: () -> Void
    let back: () -> Void

    var body: some View {
        SheetPage(
            title: "Allow alerts.",
            message: "So Spotter keeps working when your screen is locked.",
            primary: "Continue",
            primaryEnabled: notifications.isAllowed,
            secondary: notifications.isAllowed ? nil : "Not Now",
            onBack: back,
            onPrimary: next,
            onSecondary: next
        ) {
            VStack(spacing: 14) {
                OptionCard(symbol: "bell.badge.fill", title: "Notifications", detail: "Loud alarms, even when locked.", selected: notifications.isAllowed) {
                    Task { await notifications.requestPermission() }
                }
                OptionCard(symbol: "location.fill", title: "Location", detail: "So a text can say where you are.", selected: location.isAllowed) {
                    location.requestPermission()
                }
            }
            .padding(.top, 20)
        }
        .onAppear { notifications.refresh() }
    }
}

private struct TestStep: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.server) private var server
    let next: () -> Void
    let back: () -> Void
    @State private var sent = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        SheetPage(
            title: sent ? "Did they get it?" : "Send a test text.",
            message: sent ? "Tap each person who did." : "Make sure it reaches your contacts.",
            primary: sent ? "Continue" : (sending ? "Sending…" : "Send Test"),
            primaryEnabled: !sending,
            secondary: sent ? nil : "Not Now",
            onBack: back,
            onPrimary: { sent ? next() : send() },
            onSecondary: next
        ) {
            VStack(spacing: 12) {
                ForEach($store.data.contacts) { $contact in
                    OptionCard(
                        symbol: "person.fill",
                        title: contact.name,
                        detail: PhoneNumber.display(contact.phone),
                        selected: sent && contact.testConfirmed
                    ) {
                        if sent { contact.testConfirmed.toggle() }
                    }
                }
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.danger)
                }
            }
            .padding(.top, 12)
        }
    }

    private func send() {
        guard server.isConfigured else {
            error = "Texting isn't set up yet. You can test later in Settings."
            return
        }
        sending = true
        error = nil
        let firstName = store.data.firstName
        let contacts = store.data.contacts
        Task { @MainActor in
            defer { sending = false }
            do {
                let results = try await server.sendTest(firstName: firstName, contacts: contacts)
                if results.contains(where: { !$0.sent }) { error = "Some texts didn't send. Check the numbers." }
                withAnimation { sent = true }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct DoneStep: View {
    let finish: () -> Void

    var body: some View {
        SheetPage(
            title: "You're all set.",
            message: "Tap Start whenever you use. That's it.",
            primary: "Done",
            onPrimary: finish
        ) {
            ArtPanel(height: 340) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 110))
                    .foregroundStyle(.white, Theme.accent)
            }
        } content: {
            EmptyView()
        }
    }
}

/// A simple phone outline for illustrations.
struct PhoneMock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        RoundedRectangle(cornerRadius: 44, style: .continuous)
            .fill(Color.black)
            .frame(width: 250, height: 330)
            .overlay(content)
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.7)).frame(width: 90, height: 5).padding(.bottom, 12)
            }
            .offset(y: 30)
            .clipped()
    }
}
