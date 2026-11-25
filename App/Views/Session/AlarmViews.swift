import SafetyCore
import SwiftUI

/// Full-screen check-in: one question, one giant button, a countdown.
struct CheckInView: View {
    @EnvironmentObject private var session: SessionManager
    let reason: TriggerReason
    let deadline: Date
    @State private var total: TimeInterval = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            let flash = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0

            VStack(spacing: 0) {
                Text("Are you OK?")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .padding(.top, 48)

                Spacer()

                Button {
                    session.confirmOK()
                } label: {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.25), lineWidth: 12)
                        Circle()
                            .trim(from: 0, to: total > 0 ? remaining / total : 0)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: remaining)
                        Circle()
                            .fill(Color.white)
                            .padding(24)
                        Text("I'm OK")
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.danger)
                    }
                    .frame(width: 300, height: 300)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("I'm OK")

                Spacer()

                Text("Texting your contacts in \(Int(remaining.rounded(.up)))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.bottom, 48)
            }
            .foregroundStyle(.white)
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
    let reason: TriggerReason

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 64, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Your contacts were texted")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Spacer()

            Link(destination: URL(string: "tel:911")!) {
                Label("Call 911", systemImage: "phone.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(Theme.danger)
            }

            HoldToConfirmButton(title: "Hold: I'm safe", seconds: 2, tint: .white) {
                session.markSafe()
            }

            HoldToConfirmButton(title: "Hold: end without texting", seconds: 2, tint: .white.opacity(0.6)) {
                session.endSession()
            }
            .scaleEffect(0.92)
        }
        .padding(24)
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
        SheetPage(
            title: "Session ended.",
            message: summary.alertWentOut && !summary.safeTextSent
                ? "Let your contacts know you're OK."
                : "Watched for \(Format.duration(summary.duration)).",
            primary: "Done",
            onPrimary: { session.dismissSummary() }
        ) {
            ArtPanel(height: 340) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 110))
                    .foregroundStyle(.white, Theme.good)
            }
        } content: {
            EmptyView()
        }
    }
}
