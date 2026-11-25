import SafetyCore
import SwiftUI

/// The screen during a session: big numbers, connection status, time running.
/// Also shown while the session is starting up.
struct MonitoringView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var hub: SensorHub
    @EnvironmentObject private var connectivity: ConnectivityMonitor

    var body: some View {
        VStack(spacing: 24) {
            statusPill
                .padding(.top, 12)

            Spacer(minLength: 0)

            ReadingDisplay(reading: hub.latest, quality: quality)

            if case let .starting(message) = session.phase {
                ProgressView(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            } else {
                timeBlock
            }

            Spacer(minLength: 0)

            serverStatus

            Text("Leave Spotter running. You can lock the screen, but don't swipe the app away.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .starting = session.phase {
                Button("Cancel") { session.cancelStart() }
                    .font(.headline)
                    .frame(height: 50)
            } else {
                HoldToConfirmButton(title: "Hold to end session", tint: .accentColor) {
                    session.endSession()
                }
            }
        }
        .padding()
    }

    private var quality: ReadingQuality? {
        hub.latest?.quality(minimumPerfusionIndex: session.engine.settings.minimumPerfusionIndex)
    }

    private var statusPill: some View {
        let status = statusText
        let color = status.1
        return Label(status.0, systemImage: "circle.fill")
            .font(.headline)
            .labelStyle(StatusLabelStyle(color: color))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var statusText: (String, Color) {
        if case .starting = session.phase { return ("Starting", .orange) }
        if hub.status != .connected {
            return ("Oximeter disconnected", .red)
        }
        switch quality {
        case .valid?: return ("Watching", .green)
        case .weak?: return ("Weak signal. Keep your hand still and warm.", .orange)
        case .noData?, nil: return ("No reading. Check your finger.", .red)
        }
    }

    private var timeBlock: some View {
        VStack(spacing: 4) {
            if let startedAt = session.startedAt {
                Text(Format.duration(session.now.timeIntervalSince(startedAt)))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text("running").font(.subheadline).foregroundStyle(.secondary)
            }
            if let endsAt = session.endsAt {
                Text("Ends at \(Format.time(endsAt))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        if !connectivity.isOnline {
            WarningRow(text: "No internet. The alarm still works; texts will send when you're back online.", severity: .problem)
        } else if !session.serverSessionReady {
            WarningRow(text: "Connecting to the text service…", severity: .caution)
        } else if let battery = hub.batteryPercent, battery <= 33 {
            WarningRow(text: "Oximeter battery is low.", severity: .caution)
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(color).font(.caption)
            configuration.title
        }
    }
}
