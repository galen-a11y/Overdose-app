import SafetyCore
import UIKit
import SwiftUI

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
                VStack(alignment: .leading, spacing: 24) {
                    sensorCard

                    VStack(alignment: .leading, spacing: 8) {
                        Text("End on its own after").font(.headline)
                        Picker("Session length", selection: durationBinding) {
                            ForEach(durations) { option in
                                Text(option.label).tag(option.seconds)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    let warnings = preflightWarnings
                    if !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(warnings, id: \.text) { WarningRow(text: $0.text, severity: $0.severity) }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }

                    if let error = session.startError {
                        WarningRow(text: error, severity: .problem)
                    }

                    BigButton(title: "Start", height: 84) {
                        session.start(duration: store.data.defaultDuration)
                    }
                    .disabled(hub.sensor == nil)

                    Text("Start before you use. If your oxygen stays low or the signal goes quiet and you don't respond, Spotter texts \(contactNames).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    neverUseAlone
                }
                .padding()
            }
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

    private var sensorCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "sensor.fill")
                .font(.title2)
                .foregroundStyle(hub.status == .connected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.sensorName.isEmpty ? "Oximeter" : hub.sensorName).font(.headline)
                Text(sensorDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let spo2 = hub.latest?.spo2 {
                Text("\(spo2)%").font(.title2.weight(.bold)).monospacedDigit()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sensorDetail: String {
        var parts = [hub.status.label]
        if let battery = hub.batteryPercent { parts.append("battery \(battery)%") }
        if hub.status == .connected, hub.latest?.spo2 == nil { parts.append("put it on your finger") }
        return parts.joined(separator: " · ")
    }

    private var neverUseAlone: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spotter is a backup, not a guarantee.").font(.subheadline.weight(.semibold))
            Text("Never Use Alone is a free, confidential line. A volunteer stays on the phone and sends help if you stop responding.")
                .font(.footnote).foregroundStyle(.secondary)
            Link("Call Never Use Alone: 800-484-3731", destination: URL(string: "tel:18004843731")!)
                .font(.footnote.weight(.semibold))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var contactNames: String {
        let names = store.data.contacts.map(\.name)
        switch names.count {
        case 0: return "your contacts"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    private var durationBinding: Binding<TimeInterval?> {
        Binding(get: { store.data.defaultDuration }, set: { store.data.defaultDuration = $0 })
    }

    private struct Warning {
        let text: String
        let severity: WarningRow.Severity
    }

    /// Things worth knowing before starting. None of them block Start: a
    /// local alarm is still better than nothing.
    private var preflightWarnings: [Warning] {
        var list: [Warning] = []
        if hub.sensor == nil {
            list.append(Warning(text: "No oximeter is paired. Pair one in Settings.", severity: .problem))
        }
        if store.data.contacts.isEmpty {
            list.append(Warning(text: "No emergency contacts. Add at least one in Settings.", severity: .problem))
        }
        if !server.isConfigured {
            list.append(Warning(text: "Texting isn't set up in this build. The alarm works, but no one will be texted.", severity: .problem))
        }
        if !connectivity.isOnline {
            list.append(Warning(text: "No internet connection. The alarm still works, and texts will send once you're back online.", severity: .problem))
        }
        if battery.isLowForStart, let percent = battery.percent {
            list.append(Warning(text: "Phone battery is at \(percent)%. Plug in if you can.", severity: .caution))
        }
        if let sensorBattery = hub.batteryPercent, sensorBattery <= 33 {
            list.append(Warning(text: "The oximeter battery is low. A dead sensor counts as lost signal.", severity: .caution))
        }
        if !notifications.isAllowed {
            list.append(Warning(text: "Notifications are off, so the alarm can't reach you if Spotter is in the background.", severity: .problem))
        }
        if !location.isAllowed {
            list.append(Warning(text: "Location is off, so alerts can't say where you are.", severity: .problem))
        }
        if alarm.outputVolume < 0.5 {
            list.append(Warning(text: "Your volume is low. Turn it up so the alarm is loud.", severity: .caution))
        }
        if !store.data.contacts.isEmpty, store.data.contacts.contains(where: { !$0.testConfirmed }) {
            list.append(Warning(text: "Not every contact has confirmed the test text. Send a test in Settings.", severity: .caution))
        }
        return list
    }
}
