import SafetyCore
import SwiftUI

/// Full-screen check-in: flashing screen, countdown, one giant button.
struct CheckInView: View {
    @EnvironmentObject private var session: SessionManager
    let reason: TriggerReason
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let flash = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            let secondsLeft = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))

            VStack(spacing: 20) {
                Text("Are you OK?")
                    .font(.system(size: 44, weight: .heavy))
                Text(Format.reason(reason))
                    .font(.title3)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                Text("\(secondsLeft)")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("\(secondsLeft) seconds left")
                Text("seconds until your contacts are texted")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                Button {
                    session.confirmOK()
                } label: {
                    Text("I'm OK")
                        .font(.system(size: 48, weight: .heavy))
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.red)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .accessibilityHint("Stops the alarm and keeps monitoring")
            }
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(flash ? Color.red : Color(red: 0.45, green: 0, blue: 0))
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden()
    }
}

/// After the countdown: contacts were texted, the alarm keeps going.
struct AlertedView: View {
    @EnvironmentObject private var session: SessionManager
    @EnvironmentObject private var store: AppStore
    let reason: TriggerReason

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 64))
                .padding(.top, 24)
            Text("Your contacts were texted")
                .font(.largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
            Text("\(names) got a text with your location. \(Format.reason(reason)) If you need help now, call 911.")
                .font(.title3)
                .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            Link(destination: URL(string: "tel:911")!) {
                Text("Call 911")
                    .font(.title2.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            HoldToConfirmButton(title: "Hold: I'm safe now", seconds: 2, tint: .white, prominent: false) {
                session.markSafe()
            }
            Text("Stops the alarm, texts your contacts that you're safe, and ends the session.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .opacity(0.85)

            HoldToConfirmButton(title: "Hold: end without texting", seconds: 2, tint: .white) {
                session.endSession()
            }
            .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.6, green: 0, blue: 0).ignoresSafeArea())
    }

    private var names: String {
        let list = store.data.contacts.map(\.name)
        return list.isEmpty ? "Your contacts" : ListFormatter.localizedString(byJoining: list)
    }
}

struct SessionSummaryView: View {
    @EnvironmentObject private var session: SessionManager
    let summary: SessionManager.Summary

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Session ended").font(.largeTitle.weight(.bold))
            Text("Ran for \(Format.duration(summary.duration)).")
                .font(.title3)
                .foregroundStyle(.secondary)
            if summary.safeTextSent {
                Text("Your contacts are being told you're safe.").multilineTextAlignment(.center)
            } else if summary.alertWentOut {
                Text("Your contacts were texted during this session. Let them know you're OK.")
                    .multilineTextAlignment(.center)
            }
            Spacer()
            BigButton(title: "Done") { session.dismissSummary() }
        }
        .padding()
    }
}
