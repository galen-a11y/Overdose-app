import SafetyCore
import SwiftUI

/// The screen during a session. Dark and calm, because it's often watched in
/// a dim room; the numbers are big enough to read at arm's length.
/// Also shown while the session is starting up.
struct MonitoringView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var hub: SensorHub
    @EnvironmentObject private var connectivity: ConnectivityMonitor

    private var isStarting: Bool {
        if case .starting = session.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StatusPill(text: status.text, color: status.color, pulsing: status.pulsing)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)

            Spacer(minLength: 12)

            ZStack {
                OxygenRing(
                    spo2: hub.latest?.spo2,
                    threshold: session.engine.settings.lowSpO2Threshold,
                    quality: quality,
                    size: 260,
                    trackColor: Color.white.opacity(0.08)
                )
                if isStarting, hub.latest?.spo2 == nil {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                PulseTile(pulse: quality == .valid ? hub.latest?.pulseRate : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 14, fill: Theme.nightSurface)
                SignalBars(perfusionIndex: hub.latest?.perfusionIndex, minimum: session.engine.settings.minimumPerfusionIndex)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 14, fill: Theme.nightSurface)
            }

            if case let .starting(message) = session.phase {
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)
            } else {
                timeRow.padding(.top, 12)
            }

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                serverStatus
                Text("You can lock your phone. Don't swipe Spotter away.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if isStarting {
                    Button("Cancel") { session.cancelStart() }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    HoldToConfirmButton(title: "Hold to end session", systemImage: "stop.fill", tint: .white) {
                        session.endSession()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.night.ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var quality: ReadingQuality? {
        hub.latest?.quality(minimumPerfusionIndex: session.engine.settings.minimumPerfusionIndex)
    }

    private var status: (text: String, color: Color, pulsing: Bool) {
        if isStarting { return ("Getting a steady reading", Theme.caution, true) }
        if hub.status != .connected { return ("Oximeter disconnected", Theme.danger, true) }
        switch quality {
        case .valid?: return ("Watching", Theme.good, true)
        case .weak?: return ("Weak signal. Keep your hand still and warm.", Theme.caution, true)
        case .noData?, nil: return ("No reading. Check your finger.", Theme.danger, true)
        }
    }

    private var timeRow: some View {
        HStack(spacing: 12) {
            if let startedAt = session.startedAt {
                tile(value: Format.duration(session.now.timeIntervalSince(startedAt)), label: "Running", symbol: "clock")
            }
            if let endsAt = session.endsAt {
                tile(value: Format.time(endsAt), label: "Ends at", symbol: "timer")
            } else {
                tile(value: "Until you end it", label: "No time limit", symbol: "infinity")
            }
        }
    }

    private func tile(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, fill: Theme.nightSurface)
    }

    @ViewBuilder
    private var serverStatus: some View {
        if !connectivity.isOnline {
            WarningRow(text: "No internet. The alarm still works; texts send when you're back online.", severity: .problem)
        } else if !isStarting, !session.serverSessionReady {
            WarningRow(text: "Connecting to the text service…", severity: .caution)
        } else if let battery = hub.batteryPercent, battery <= 33 {
            WarningRow(text: "Oximeter battery is low.", severity: .caution)
        }
    }
}
