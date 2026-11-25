import SafetyCore
import SwiftUI

/// The screen during a session: a dark, quiet room with one number.
/// Also shown while the session is starting up.
struct MonitoringView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var hub: SensorHub
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @State private var showTip = true

    private var isStarting: Bool {
        if case .starting = session.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusPill(text: status.text, color: status.color, pulsing: true)
                .padding(.top, 12)

            Spacer()

            ZStack {
                OxygenRing(
                    spo2: hub.latest?.spo2,
                    threshold: session.engine.settings.lowSpO2Threshold,
                    quality: quality,
                    size: 270,
                    trackColor: Color.white.opacity(0.07)
                )
                if isStarting, hub.latest?.spo2 == nil {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }

            HStack(spacing: 18) {
                Label(pulseText, systemImage: "heart.fill")
                    .symbolEffect(.pulse, options: .repeating, isActive: quality == .valid)
                if let elapsed = elapsedText {
                    Label(elapsed, systemImage: "clock")
                }
            }
            .font(.system(.title3, design: .rounded).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.top, 28)

            Spacer()

            if let problem {
                Text(problem)
                    .font(.subheadline)
                    .foregroundStyle(Theme.caution)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
            } else if showTip, !isStarting {
                Text("You can lock your phone. Keep Spotter open.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .padding(.bottom, 12)
            }

            if isStarting {
                Button("Cancel") { session.cancelStart() }
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                HoldToConfirmButton(title: "Hold to end", tint: .white.opacity(0.8)) {
                    session.endSession()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.night.ignoresSafeArea())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                withAnimation { showTip = false }
            }
        }
    }

    private var quality: ReadingQuality? {
        hub.latest?.quality(minimumPerfusionIndex: session.engine.settings.minimumPerfusionIndex)
    }

    private var pulseText: String {
        guard quality == .valid, let pulse = hub.latest?.pulseRate else { return "--" }
        return "\(pulse)"
    }

    private var elapsedText: String? {
        guard !isStarting, let startedAt = session.startedAt else { return nil }
        return Format.duration(session.now.timeIntervalSince(startedAt))
    }

    private var status: (text: String, color: Color) {
        if isStarting { return ("Starting", Theme.caution) }
        if hub.status != .connected { return ("Reconnecting", Theme.danger) }
        switch quality {
        case .valid?: return ("Watching", Theme.good)
        case .weak?: return ("Weak signal", Theme.caution)
        case .noData?, nil: return ("No reading", Theme.danger)
        }
    }

    /// One short line, only when something needs attention.
    private var problem: String? {
        if isStarting { return "Hold still for a moment." }
        if !connectivity.isOnline { return "No internet. The alarm still works." }
        if quality == .weak { return "Keep your hand still and warm." }
        if hub.status == .connected, quality != .valid { return "Check the oximeter is on your finger." }
        return nil
    }
}
