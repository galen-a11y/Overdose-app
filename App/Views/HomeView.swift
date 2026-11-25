import SafetyCore
import SwiftUI
import UIKit

/// Calm and nearly empty: one button. Tapping it opens a short sheet to pick
/// how long, then Start.
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
    @State private var showStart = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color(white: 0.16), in: Circle())
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            Button { showStart = true } label: {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(canStart ? 0.14 : 0.05))
                        .frame(width: 260, height: 260)
                        .phaseAnimator([1.0, 1.06]) { view, scale in
                            view.scaleEffect(canStart ? scale : 1)
                        } animation: { _ in .easeInOut(duration: 3) }
                    Circle()
                        .fill(canStart ? Theme.accent : Color(white: 0.24))
                        .frame(width: 204, height: 204)
                    Text("Start")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(canStart ? Color.white : Color(white: 0.5))
                }
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!canStart)
            .accessibilityLabel("Start session")

            Text(store.data.firstName.isEmpty ? " " : "Hi, \(store.data.firstName)")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 32)

            Spacer()

            if let issue = topIssue {
                Button { showSettings = true } label: {
                    Label(issue, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.caution)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color(white: 0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
            } else if let error = session.startError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) { SettingsView().preferredColorScheme(.dark) }
        .sheet(isPresented: $showStart) {
            StartSheet { duration in
                showStart = false
                store.data.defaultDuration = duration
                session.start(duration: duration)
            } cancel: {
                showStart = false
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            notifications.refresh()
            hub.acquire("home")
        }
        .onDisappear { hub.release("home") }
    }

    private var canStart: Bool { hub.sensor != nil }

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

/// "How long?" with four choices, then Start. The last choice is remembered.
private struct StartSheet: View {
    @EnvironmentObject private var store: AppStore
    let start: (TimeInterval?) -> Void
    let cancel: () -> Void
    @State private var selection: TimeInterval?? = nil

    private let options: [(symbol: String, title: String, seconds: TimeInterval?)] = [
        ("infinity", "Until I end it", nil),
        ("1.circle.fill", "1 hour", 3600),
        ("2.circle.fill", "2 hours", 7200),
        ("4.circle.fill", "4 hours", 14400),
    ]

    private var chosen: TimeInterval? {
        selection ?? store.data.defaultDuration
    }

    var body: some View {
        SheetPage(
            title: "Start watching.",
            message: "Spotter checks in if something looks wrong. It can end on its own.",
            primary: "Start",
            secondary: "Not Now",
            onPrimary: { start(chosen) },
            onSecondary: cancel
        ) {
            VStack(spacing: 12) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    OptionCard(symbol: option.symbol, title: option.title, selected: chosen == option.seconds) {
                        selection = .some(option.seconds)
                    }
                }
            }
        }
        .presentationCornerRadius(40)
        .presentationBackground(Theme.sheet)
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
