import SafetyCore
import SwiftUI

/// Scan, tap the oximeter, confirm a live reading.
struct PairSensorView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var hub: SensorHub
    @StateObject private var scanner = OximeterScanner()
    let onDone: () -> Void

    var body: some View {
        List {
            Section {
                Text("Turn the oximeter on by putting it on your finger. It should show up below within a few seconds.")
                    .font(.subheadline)
                if let problem = scanner.bluetoothProblem {
                    WarningRow(text: problem, severity: .problem)
                }
            }

            if store.data.pairedSensorID != nil || store.data.useFakeSensor {
                Section("Live reading") {
                    VStack(spacing: 12) {
                        Text(hub.sensorName).font(.headline)
                        Text(hub.status.label).font(.subheadline).foregroundStyle(.secondary)
                        ReadingDisplay(reading: hub.latest, quality: hub.latest?.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex))
                            .scaleEffect(0.7)
                        if hasValidReading {
                            Label("Reading looks good", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Waiting for a reading. Keep your hand still.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Button("Use this oximeter") { onDone() }
                        .font(.headline)
                        .disabled(!hasValidReading)
                }
            }

            Section {
                ForEach(scanner.visibleDevices) { device in
                    Button {
                        pair(device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.headline)
                                Text(device.likelyOximeter ? "Looks like a Wellue / Viatom oximeter" : "Unknown device")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id == store.data.pairedSensorID {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                if scanner.visibleDevices.isEmpty {
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                }
                Toggle("Show all Bluetooth devices", isOn: $scanner.showAllDevices)
            } header: {
                Text("Nearby oximeters")
            } footer: {
                Text("Built for the Wellue / Viatom PC-60FW family (sold as the Bluetooth OxySmart). Check the model on the label.")
            }

            Section {
                Toggle("Use a fake oximeter (testing)", isOn: $store.data.useFakeSensor)
            } footer: {
                Text("For trying Spotter without the device. Pick a scenario in Settings > Developer.")
            }
        }
        .navigationTitle("Pair your oximeter")
        .onAppear {
            scanner.start()
            hub.acquire("pairing")
        }
        .onDisappear {
            scanner.stop()
            hub.release("pairing")
        }
    }

    private var hasValidReading: Bool {
        hub.latest?.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex) == .valid
    }

    private func pair(_ device: OximeterScanner.Device) {
        store.data.useFakeSensor = false
        store.data.pairedSensorID = device.id
        store.data.pairedSensorName = device.name
        // The hub rebuilds its sensor from the store change; start it once that lands.
        DispatchQueue.main.async { hub.acquire("pairing") }
    }
}
