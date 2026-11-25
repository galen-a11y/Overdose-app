import SafetyCore
import SwiftUI
import UIKit

/// Calm and nearly empty: one button to start. A single line appears only
/// when something needs fixing.
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
    @State private var startTaps = 0

    private struct Duration: Identifiable {
        let label: String
        let seconds: TimeInterval?
        var id: String { label }
    }

    private let durations = [
        Duration(label: "No time limit", seconds: nil),
        Duration(label: "1 hour", seconds: 3600),
        Duration(label: "2 hours", seconds: 7200),
        Duration(label: "4 hours", seconds: 14400),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 12)

            Spacer()

            Text(store.data.firstName.isEmpty ? "Hi" : "Hi, \(store.data.firstName)")
                .font(.system(.title2, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            startButton

            durationMenu
                .padding(.top, 28)

            Spacer()

            if let issue = topIssue {
                Button { showSettings = true } label: {
                    Label(issue, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.caution)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.caution.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
            } else if let error = session.startError {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Theme.background, Theme.accent.opacity(0.10)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            notifications.refresh()
            hub.acquire("home")
        }
        .onDisappear { hub.release("home") }
    }

    private var canStart: Bool { hub.sensor != nil }

    private var startButton: some View {
        Button {
            startTaps += 1
            session.start(duration: store.data.defaultDuration)
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(canStart ? 0.10 : 0.04))
                    .frame(width: 250, height: 250)
                    .phaseAnimator([1.0, 1.07]) { view, scale in
                        view.scaleEffect(canStart ? scale : 1)
                    } animation: { _ in .easeInOut(duration: 3) }
                Circle()
                    .fill(canStart ? Theme.accent : Color.secondary.opacity(0.3))
                    .frame(width: 200, height: 200)
                    .shadow(color: Theme.accent.opacity(canStart ? 0.3 : 0), radius: 20, y: 10)
                Text("Start")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canStart)
        .sensoryFeedback(.impact(weight: .medium), trigger: startTaps)
        .accessibilityLabel("Start session")
    }

    private var durationMenu: some View {
        Menu {
            Picker("Session length", selection: durationBinding) {
                ForEach(durations) { option in
                    Text(option.label).tag(option.seconds)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text(durationLabel)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface.opacity(0.8), in: Capsule())
        }
    }

    private var durationLabel: String {
        durations.first { $0.seconds == store.data.defaultDuration }?.label ?? "No time limit"
    }

    private var durationBinding: Binding<TimeInterval?> {
        Binding(get: { store.data.defaultDuration }, set: { store.data.defaultDuration = $0 })
    }

    /// The single most important thing to fix, in a few words. Tapping it opens Settings.
    private var topIssue: String? {
        if hub.sensor == nil { return "Connect your oximeter" }
        if store.data.contacts.isEmpty { return "Add a contact" }
        if !connectivity.isOnline { return "No internet. Texts will wait." }
        if !notifications.isAllowed { return "Turn on notifications" }
        if !location.isAllowed { return "Turn on location" }
        if !server.isConfigured { return "Texting isn't set up yet" }
        if battery.isLowForStart { return "Phone battery is low" }
        if let level = hub.batteryPercent, level <= 33 { return "Oximeter battery is low" }
        if alarm.outputVolume < 0.5 { return "Turn your volume up" }
        return nil
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
