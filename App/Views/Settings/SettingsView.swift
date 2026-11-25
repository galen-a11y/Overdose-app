import SafetyCore
import UIKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var hub: SensorHub
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var location: LocationService
    @Environment(\.server) private var server
    @Environment(\.dismiss) private var dismiss
    @State private var confirmErase = false

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    Label {
                        TextField("First name", text: $store.data.firstName)
                            .textContentType(.givenName)
                    } icon: {
                        Image(systemName: "person.fill")
                    }
                }

                Section("Emergency contacts") {
                    NavigationLink {
                        ContactsEditor()
                            .navigationTitle("Contacts")
                    } label: {
                        Label {
                            LabeledContent("Contacts", value: "\(store.data.contacts.count) of 3")
                        } icon: {
                            Image(systemName: "person.2.fill")
                        }
                    }
                    NavigationLink {
                        TestTextScreen()
                    } label: {
                        Label("Send a test text", systemImage: "paperplane.fill")
                    }
                }

                AlertRulesSection(settings: $store.data.alertSettings)

                Section("Oximeter") {
                    LabeledContent("Device", value: hub.sensorName.isEmpty ? "None" : hub.sensorName)
                    LabeledContent("Status", value: hub.status.label)
                    if let battery = hub.batteryPercent {
                        LabeledContent("Battery", value: "about \(battery)%")
                    }
                    NavigationLink {
                        PairSensorView()
                    } label: {
                        Label("Pair a different oximeter", systemImage: "sensor.fill")
                    }
                    NavigationLink {
                        RawPacketView()
                    } label: {
                        Label("Raw Bluetooth packets", systemImage: "waveform.path.ecg")
                    }
                }

                Section {
                    LabeledContent("Notifications", value: notifications.isAllowed ? "On" : "Off")
                    LabeledContent("Critical Alerts", value: notifications.criticalAlertsEnabled ? "On" : "Not available yet")
                    LabeledContent("Location", value: location.isAllowed ? "On" : "Off")
                    LabeledContent("Text service", value: server.isConfigured ? "Set up" : "Not set up in this build")
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } header: {
                    Text("Permissions")
                }

                Section {
                    Toggle("Use fake oximeter", isOn: $store.data.useFakeSensor)
                    Picker("Scenario", selection: $store.data.fakeScenario) {
                        ForEach(SensorScenario.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!store.data.useFakeSensor)
                } header: {
                    Text("Developer")
                }

                Section {
                    NavigationLink {
                        SafetyInfoView()
                    } label: {
                        Label("About Spotter and safety", systemImage: "info.circle.fill")
                    }
                    Button("Erase all data on this phone", role: .destructive) { confirmErase = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Erase your name, contacts, oximeter and settings?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) {
                    store.eraseAll()
                    dismiss()
                }
            }
            .onAppear { notifications.refresh() }
        }
    }
}

private struct AlertRulesSection: View {
    @Binding var settings: AlertSettings

    var body: some View {
        Section {
            Stepper(value: $settings.lowSpO2Threshold, in: AlertSettings.thresholdRange) {
                LabeledContent("Low oxygen below", value: "\(settings.lowSpO2Threshold)%")
            }
            Stepper(value: $settings.lowSpO2Duration, in: AlertSettings.lowDurationRange, step: 5) {
                LabeledContent("For at least", value: "\(Int(settings.lowSpO2Duration)) sec")
            }
            Stepper(value: $settings.signalLossTimeout, in: AlertSettings.signalLossRange, step: 5) {
                LabeledContent("Signal lost after", value: "\(Int(settings.signalLossTimeout)) sec")
            }
            Stepper(value: $settings.checkInCountdown, in: AlertSettings.countdownRange, step: 5) {
                LabeledContent("Check-in countdown", value: "\(Int(settings.checkInCountdown)) sec")
            }
            Stepper(value: $settings.minimumPerfusionIndex, in: AlertSettings.perfusionRange, step: 0.1) {
                LabeledContent("Skip readings with signal below", value: String(format: "%.1f%%", settings.minimumPerfusionIndex))
            }
            Button("Reset to starting settings") { settings = .default }
        } header: {
            Text("Alert rules")
        } footer: {
            Text("Placeholders until a clinician reviews them.")
        }
    }
}

struct RawPacketView: View {
    @EnvironmentObject private var hub: SensorHub

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: hub.status.label)
                if let reading = hub.latest {
                    LabeledContent("SpO2", value: reading.spo2.map { "\($0)%" } ?? "none")
                    LabeledContent("Pulse", value: reading.pulseRate.map { "\($0) bpm" } ?? "none")
                    LabeledContent("Perfusion index", value: reading.perfusionIndex.map { String(format: "%.1f%%", $0) } ?? "none")
                }
                if let summary = hub.decoderSummary {
                    Text(summary).font(.footnote)
                }
            } footer: {
                Text("Frames should start with AA 55 and match the oximeter's screen.")
            }
            Section("Newest first") {
                ForEach(Array(hub.rawLog.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Raw packets")
        .onAppear { hub.acquire("raw") }
        .onDisappear { hub.release("raw") }
    }
}

struct SafetyInfoView: View {
    var body: some View {
        List {
            Section("What Spotter does") {
                Text("During a session it watches your oximeter. If your oxygen stays low, or the reading stops, it sounds an alarm and asks if you're OK. If you don't answer in time, it texts your contacts your first name, what happened, and a map link.")
                Text("If the app stops running (the phone dies or the app is swiped away), the server notices within about two minutes and texts your contacts that it lost contact.")
            }
            Section("It's a backup, not a guarantee") {
                Text("Phones die, sensors slip off, and texts can be delayed. Fingertip oximeters aren't made for hours of wear and can give bad readings with movement or cold hands.")
                Text("Spotter is not a medical device and doesn't diagnose or treat anything.")
            }
            Section("Other ways to stay safer") {
                Link("Never Use Alone: 800-484-3731", destination: URL(string: "tel:18004843731")!)
                Text("A free, confidential, peer-run line. A volunteer stays on the phone and sends help to your location if you stop responding.")
                Text("Ask your contacts to keep naloxone (Narcan) and know how to use it.")
            }
            Section("Privacy") {
                Text("No account. Your name, contacts and settings stay on this phone. During a session the server holds your contacts' numbers and your last location, and deletes them when the session ends. Texts never mention drugs.")
            }
        }
        .navigationTitle("About Spotter")
    }
}

/// Test text from Settings.
struct TestTextScreen: View {
    @State private var sent = false

    var body: some View {
        ScrollView {
            TestTextPanel(sent: $sent).padding()
        }
        .background(Theme.background)
        .navigationTitle("Test text")
    }
}
