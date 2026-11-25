import SafetyCore
import SwiftUI

/// Finds the oximeter, connects, and shows the live number once it's reading.
/// Used in setup and in Settings.
struct OximeterPairing: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var hub: SensorHub
    @StateObject private var scanner = OximeterScanner()

    var body: some View {
        VStack(spacing: 16) {
            if isPaired {
                OxygenRing(
                    spo2: hub.latest?.spo2,
                    threshold: store.data.alertSettings.lowSpO2Threshold,
                    quality: hub.latest?.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex),
                    size: 180
                )
                .padding(.vertical, 8)
                Text(isReading ? "Connected" : "Put it on your finger")
                    .font(.headline)
                    .foregroundStyle(isReading ? Theme.good : .secondary)
                Button("Choose a different one") {
                    store.data.pairedSensorID = nil
                    store.data.useFakeSensor = false
                }
                .font(.subheadline)
            } else {
                if let problem = scanner.bluetoothProblem {
                    Text(problem).font(.subheadline).foregroundStyle(Theme.danger)
                }
                ForEach(scanner.visibleDevices) { device in
                    Button { pair(device) } label: {
                        HStack(spacing: 12) {
                            IconBadge(systemName: "sensor.fill", size: 40)
                            Text(device.name).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .card(padding: 12)
                    }
                    .buttonStyle(.plain)
                }
                if scanner.visibleDevices.isEmpty, scanner.bluetoothProblem == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking…").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: isPaired)
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

    var isReading: Bool {
        hub.latest?.quality(minimumPerfusionIndex: store.data.alertSettings.minimumPerfusionIndex) == .valid
    }

    private func pair(_ device: OximeterScanner.Device) {
        store.data.useFakeSensor = false
        store.data.pairedSensorID = device.id
        store.data.pairedSensorName = device.name
        DispatchQueue.main.async { hub.acquire("pairing") }
    }
}

/// Settings wrapper.
struct PairSensorView: View {
    var body: some View {
        ScrollView {
            OximeterPairing().padding()
        }
        .navigationTitle("Oximeter")
    }
}
