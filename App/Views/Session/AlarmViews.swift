import SafetyCore
import SwiftUI

/// Full-screen check-in: flashing screen, a countdown ring around one giant button.
struct CheckInView: View {
    @EnvironmentObject private var session: SessionManager
    let reason: TriggerReason
    let deadline: Date
    @State private var total: TimeInterval = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let secondsLeft = Int(remaining.rounded(.up))
            let flash = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0

            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Are you OK?")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                    Text(Format.reason(reason))
                        .font(.title3.weight(.medium))
                        .multilineTextAlignment(.center)
                        .opacity(0.9)
                }
                .padding(.top, 24)

                Spacer(minLength: 0)

                Button {
                    session.confirmOK()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: total > 0 ? remaining / total : 0)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: remaining)
                        Circle()
                            .fill(Color.white)
                            .padding(26)
                            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                        VStack(spacing: 4) {
                            Text("I'm OK")
                                .font(.system(size: 50, weight: .heavy, design: .rounded))
                            Text("Tap anywhere here")
                                .font(.subheadline.weight(.semibold))
                                .opacity(0.7)
                        }
                        .foregroundStyle(Theme.danger)
                    }
                    .frame(width: 300, height: 300)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("I'm OK")
                .accessibilityHint("Stops the alarm and keeps monitoring")

                Spacer(minLength: 0)

                VStack(spacing: 2) {
                    Text("\(secondsLeft)")
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    Text(secondsLeft == 1 ? "second until your contacts are texted" : "seconds until your contacts are texted")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .padding(.bottom, 24)
            }
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background((flash ? Theme.danger : Theme.alarmDark).ignoresSafeArea())
            .animation(.easeInOut(duration: 0.2), value: flash)
        }
        .statusBarHidden()
        .onAppear { total = max(1, deadline.timeIntervalSinceNow) }
    }
}

/// After the countdown: contacts were texted, the alarm keeps going.
struct AlertedView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var store: AppStore
    let reason: TriggerReason

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .padding(.top, 32)

                VStack(spacing: 8) {
                    Text("Your contacts were texted")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(Format.reason(reason))
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .opacity(0.9)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Texted with your location")
                        .font(.subheadline.weight(.semibold))
                        .opacity(0.8)
                    ForEach(store.data.contacts) { contact in
                        HStack(spacing: 12) {
                            InitialsAvatar(name: contact.name)
                            Text(contact.name).font(.headline)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                }
                .card(fill: Color.white.opacity(0.12))

                Link(destination: URL(string: "tel:911")!) {
                    Label("Call 911", systemImage: "phone.fill")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(Theme.danger)
                }

                VStack(spacing: 8) {
                    HoldToConfirmButton(title: "Hold: I'm safe now", systemImage: "hand.thumbsup.fill", seconds: 2, tint: .white) {
                        session.markSafe()
                    }
                    Text("Stops the alarm, tells your contacts you're safe, and ends the session.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .opacity(0.8)
                }

                HoldToConfirmButton(title: "Hold: end without texting", seconds: 2, tint: .white.opacity(0.7)) {
                    session.endSession()
                }
            }
            .padding()
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Theme.danger, Theme.alarmDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .environment(\.colorScheme, .dark)
    }
}

struct SessionSummaryView: View {
    @EnvironmentObject private var session: SessionManager
    let summary: SessionManager.Summary

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            IconBadge(systemName: "checkmark", tint: Theme.good, size: 96)
            VStack(spacing: 6) {
                Text("Session ended")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Watched for \(Format.duration(summary.duration))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if summary.safeTextSent {
                Label("Your contacts are being told you're safe.", systemImage: "message.fill")
                    .card()
            } else if summary.alertWentOut {
                Label("Your contacts were texted during this session. Let them know you're OK.", systemImage: "exclamationmark.bubble.fill")
                    .card()
            }
            Spacer()
            BigButton(title: "Done") { session.dismissSummary() }
        }
        .padding()
        .background(Theme.background.ignoresSafeArea())
    }
}
