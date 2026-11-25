import SafetyCore
import SwiftUI

/// A button that only fires after being held, so it can't be hit by accident
/// (ending a session, "I'm safe now"). VoiceOver users activate it normally.
struct HoldToConfirmButton: View {
    let title: String
    var seconds: Double = 1.5
    var tint: Color = .red
    var prominent = false
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isPressing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(prominent ? tint : tint.opacity(0.14))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? Color.white.opacity(0.35) : tint.opacity(0.4))
                    .frame(width: geometry.size.width * progress)
            }
            Text(isPressing ? "Keep holding…" : title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal)
        }
        .frame(height: prominent ? 72 : 58)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: seconds, maximumDistance: 60) {
            action()
        } onPressingChanged: { pressing in
            isPressing = pressing
            if pressing {
                withAnimation(.linear(duration: seconds)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press and hold to confirm")
        .accessibilityAction { action() }
    }
}

/// A big, plain call to action.
struct BigButton: View {
    let title: String
    var tint: Color = .accentColor
    var height: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct WarningRow: View {
    enum Severity { case caution, problem }
    let text: String
    var severity: Severity = .caution

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: severity == .problem ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severity == .problem ? Color.red : Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Large oxygen and pulse numbers.
struct ReadingDisplay: View {
    let reading: PulseReading?
    let quality: ReadingQuality?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            VStack(spacing: 2) {
                Text(reading?.spo2.map { "\($0)%" } ?? "--")
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                Text("Oxygen").font(.headline).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text(reading?.pulseRate.map(String.init) ?? "--")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Pulse").font(.headline).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(quality == .valid ? Color.primary : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let spo2 = reading?.spo2, let pulse = reading?.pulseRate else { return "No reading" }
        return "Oxygen \(spo2) percent, pulse \(pulse)"
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func reason(_ reason: TriggerReason) -> String {
        switch reason {
        case .lowOxygen: return "Your oxygen has been low."
        case .signalLost: return "The oximeter stopped sending a reading."
        }
    }
}
