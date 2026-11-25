import SafetyCore
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var hub: SensorHub
    @EnvironmentObject private var alarm: AlarmController
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @Environment(\.server) private var server

    @State private var showSettings = false
    @State private var showSafety = false
    @State private var showAllChecks = false
    @State private var startTaps = 0

    private struct DurationOption: Identifiable {
        let label: String
        let seconds: TimeInterval?
        var id: String { label }
    }

    private let durations = [
        DurationOption(label: "No limit", seconds: nil),
        DurationOption(label: "1 hr", seconds: 3600),
        DurationOption(label: "2 hr", seconds: 7200),
        DurationOption(label: "4 hr", seconds: 14400),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sensorCard
                    startButton
                        .padding(.vertical, 8)
                    durationPicker
                    checklistCard
                    contactsCard
                    neverUseAloneCard
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(store.data.firstName.isEmpty ? "Spotter" : "Hi, \(store.data.firstName)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSafety = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("About and safety")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showSafety) { NavigationStack { SafetyInfoView() } }
            .onAppear {
                notifications.refresh()
                hub.acquire("home")
            }
            .onDisappear { hub.release("home") }
        }
    }

    // MARK: - Sensor

    private var sensorCard: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: "sensor.fill", tint: sensorTint)
            VStack(alignment: .leading, spacing: 3) {
                Text(hub.sensorName.isEmpty ? "Oximeter" : hub.sensorName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(sensorDetail)
                    if let battery = hub.batteryPercent {
                        Image(systemName: batterySymbol(battery))
                            .foregroundStyle(battery <= 33 ? Theme.caution : .secondary)
                            .accessibilityLabel("Oximeter battery \(battery) percent")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let spo2 = hub.latest?.spo2 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(spo2)%")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("live").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private var sensorTint: Color {
        switch hub.status {
        case .connected: return Theme.good
        case .notPaired: return Theme.danger
        case .disconnected: return Theme.caution
        default: return .secondary
        }
    }

    private var sensorDetail: String {
        if hub.status == .connected, hub.latest?.spo2 == nil { return "Put it on your finger" }
        if hub.status == .connected { return "Ready" }
        return hub.status.label
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<20: return "battery.0percent"
        case ..<50: return "battery.25percent"
        case ..<80: return "battery.50percent"
        default: return "battery.100percent"
        }
    }

    // MARK: - Start

    private var canStart: Bool { hub.sensor != nil }

    private var startButton: some View {
        VStack(spacing: 14) {
            Button {
                startTaps += 1
                session.start(duration: store.data.defaultDuration)
            } label: {
                ZStack {
                    Circle()
                        .fill(canStart ? Theme.accent.opacity(0.12) : Color.secondary.opacity(0.08))
                        .frame(width: 236, height: 236)
                        .phaseAnimator([1.0, 1.06]) { view, scale in
                            view.scaleEffect(canStart ? scale : 1)
                        } animation: { _ in .easeInOut(duration: 2.2) }
                    Circle()
                        .fill(
                            canStart
                                ? AnyShapeStyle(LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.accent], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(Color.secondary.opacity(0.3))
                        )
                        .frame(width: 196, height: 196)
                        .shadow(color: Theme.accent.opacity(canStart ? 0.35 : 0), radius: 18, y: 8)
                    VStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 34, weight: .bold))
                        Text("Start").font(.system(size: 34, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canStart)
            .sensoryFeedback(.impact(weight: .medium), trigger: startTaps)
            .accessibilityLabel("Start session")
            .accessibilityHint("Starts watching your oximeter")

            if let error = session.startError {
                WarningRow(text: error, severity: .problem).card()
            } else {
                Text("Start before you use. Spotter checks in if something looks wrong.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("End on its own after", systemImage: "timer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(durations) { option in
                    let selected = store.data.defaultDuration == option.seconds
                    Button {
                        store.data.defaultDuration = option.seconds
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(selected ? Theme.accent : Theme.background, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: store.data.defaultDuration)
        }
        .card()
    }

    // MARK: - Checklist

    private struct Check: Identifiable {
        var id: String { text }
        let text: String
        let severity: WarningRow.Severity
    }

    /// Things worth knowing before starting. None of them block Start: a
    /// local alarm is still better than nothing.
    private var checks: [Check] {
        var list: [Check] = []
        if hub.sensor == nil {
            list.append(Check(text: "No oximeter is paired. Pair one in Settings.", severity: .problem))
        }
        if store.data.contacts.isEmpty {
            list.append(Check(text: "No emergency contacts. Add one in Settings.", severity: .problem))
        }
        if !server.isConfigured {
            list.append(Check(text: "Texting isn't set up in this build. The alarm works, but no one will be texted.", severity: .problem))
        }
        if !connectivity.isOnline {
            list.append(Check(text: "No internet. The alarm still works; texts send when you're back online.", severity: .problem))
        }
        if !notifications.isAllowed {
            list.append(Check(text: "Notifications are off, so the alarm can't reach you in the background.", severity: .problem))
        }
        if !location.isAllowed {
            list.append(Check(text: "Location is off, so alerts can't say where you are.", severity: .problem))
        }
        if battery.isLowForStart, let percent = battery.percent {
            list.append(Check(text: "Phone battery is at \(percent)%. Plug in if you can.", severity: .caution))
        }
        if let sensorBattery = hub.batteryPercent, sensorBattery <= 33 {
            list.append(Check(text: "Oximeter battery is low. A dead sensor counts as lost signal.", severity: .caution))
        }
        if alarm.outputVolume < 0.5 {
            list.append(Check(text: "Volume is low. Turn it up so the alarm is loud.", severity: .caution))
        }
        if !store.data.contacts.isEmpty, store.data.contacts.contains(where: { !$0.testConfirmed }) {
            list.append(Check(text: "Not every contact has confirmed the test text.", severity: .caution))
        }
        return list
    }

    private var checklistCard: some View {
        let list = checks
        let shown = showAllChecks ? list : Array(list.prefix(2))
        return VStack(alignment: .leading, spacing: 12) {
            if list.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All set").font(.headline)
                        Text("Oximeter, contacts, alarm and location are ready.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.title2)
                }
            } else {
                Text(list.count == 1 ? "1 thing to check" : "\(list.count) things to check")
                    .font(.headline)
                ForEach(shown) { WarningRow(text: $0.text, severity: $0.severity) }
                if list.count > 2 {
                    Button(showAllChecks ? "Show less" : "Show all \(list.count)") {
                        withAnimation { showAllChecks.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
        .card()
    }

    // MARK: - Contacts

    private var contactsCard: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 12) {
                HStack(spacing: -10) {
                    ForEach(store.data.contacts) { InitialsAvatar(name: $0.name) }
                    if store.data.contacts.isEmpty {
                        IconBadge(systemName: "person.badge.plus", tint: Theme.danger, size: 36)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.data.contacts.isEmpty ? "No contacts yet" : "If you don't respond")
                        .font(.headline)
                    Text(store.data.contacts.isEmpty
                         ? "Add someone who can get to you quickly."
                         : "Spotter texts \(Format.names(store.data.contacts.map(\.name))) your location.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var neverUseAloneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("A backup, not a guarantee", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            Text("Never Use Alone is free and confidential. A volunteer stays on the phone and sends help if you stop responding.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "tel:18004843731")!) {
                Label("Call 800-484-3731", systemImage: "phone.fill")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .card()
    }
}

/// Shrinks a button slightly while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
