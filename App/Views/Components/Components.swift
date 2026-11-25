import SafetyCore
import SwiftUI
import UIKit

// MARK: - Theme

/// One place for colors, shapes and type, so every screen feels like the same app.
/// Calm and quiet when things are fine; loud and unmistakable when they're not.
enum Theme {
    static let accent = Color.accentColor
    static let good = Color(red: 0.20, green: 0.68, blue: 0.47)
    static let caution = Color(red: 0.93, green: 0.60, blue: 0.13)
    static let danger = Color(red: 0.86, green: 0.18, blue: 0.20)
    static let alarmDark = Color(red: 0.42, green: 0.02, blue: 0.04)

    static let background = Color(.systemGroupedBackground)
    static let surface = Color(.secondarySystemGroupedBackground)

    /// Deep blue-green used behind the session screen. Easy on the eyes in a dark room.
    static let night = Color(red: 0.03, green: 0.08, blue: 0.09)
    static let nightSurface = Color.white.opacity(0.07)

    static let corner: CGFloat = 20
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    var fill: Color = Theme.surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16, fill: Color = Theme.surface) -> some View {
        modifier(CardModifier(padding: padding, fill: fill))
    }
}

/// An SF Symbol in a soft tinted circle.
struct IconBadge: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// A button that only fires after being held, so it can't be hit by accident
/// (ending a session, "I'm safe now"). VoiceOver users activate it normally.
struct HoldToConfirmButton: View {
    let title: String
    var systemImage: String? = nil
    var seconds: Double = 1.5
    var tint: Color = .red
    var prominent = false
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isPressing = false
    @State private var fired = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(prominent ? tint : tint.opacity(0.15))
            GeometryReader { geometry in
                Rectangle()
                    .fill(prominent ? Color.white.opacity(0.3) : tint.opacity(0.35))
                    .frame(width: geometry.size.width * progress)
            }
            HStack(spacing: 8) {
                if let systemImage, !isPressing { Image(systemName: systemImage) }
                Text(isPressing ? "Keep holding…" : title)
            }
            .font(.headline)
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal)
        }
        .frame(height: prominent ? 68 : 56)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: seconds, maximumDistance: 60) {
            fired += 1
            action()
        } onPressingChanged: { pressing in
            isPressing = pressing
            if pressing {
                withAnimation(.linear(duration: seconds)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        }
        .sensoryFeedback(.success, trigger: fired)
        .sensoryFeedback(.impact(weight: .light), trigger: isPressing) { _, new in new }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press and hold to confirm")
        .accessibilityAction { action() }
    }
}

/// The main call to action on a screen.
struct BigButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var height: CGFloat = 58
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: height)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .buttonBorderShape(.roundedRectangle(radius: 18))
    }
}

// MARK: - Status

struct WarningRow: View {
    enum Severity { case caution, problem }
    let text: String
    var severity: Severity = .caution

    var body: some View {
        Label {
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: severity == .problem ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severity == .problem ? Theme.danger : Theme.caution)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small colored capsule with a dot, for "Watching", "Weak signal" and so on.
struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .blinking(pulsing)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(color.opacity(0.18), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Gently fades a view in and out, like a status light.
    @ViewBuilder
    func blinking(_ active: Bool) -> some View {
        if active {
            self.phaseAnimator([1.0, 0.35]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.1) }
        } else {
            self
        }
    }
}

// MARK: - Readings

/// Oxygen as a ring that fills from 70% to 100%, colored by how close it is
/// to the alert threshold.
struct OxygenRing: View {
    let spo2: Int?
    let threshold: Int
    let quality: ReadingQuality?
    var size: CGFloat = 250
    var trackColor: Color = Color.primary.opacity(0.08)

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: fraction)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(spo2.map(String.init) ?? "--")
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: spo2)
                    Text("%")
                        .font(.system(size: size * 0.11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("Oxygen")
                    .font(.system(size: max(13, size * 0.065), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(quality == .valid ? 1 : 0.55)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spo2.map { "Oxygen \($0) percent" } ?? "No oxygen reading")
    }

    private var lineWidth: CGFloat { size * 0.075 }

    private var fraction: Double {
        guard let spo2, quality == .valid else { return 0 }
        return min(1, max(0.02, Double(spo2 - 70) / 30))
    }

    private var color: Color {
        guard let spo2, quality == .valid else { return .gray }
        if spo2 < threshold { return Theme.danger }
        if spo2 < threshold + 3 { return Theme.caution }
        return Theme.good
    }
}

/// Pulse with a heart that beats while there's a reading.
struct PulseTile: View {
    let pulse: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.title3)
                .foregroundStyle(pulse == nil ? Color.secondary : Theme.danger)
                .symbolEffect(.pulse, options: .repeating, isActive: pulse != nil)
            VStack(alignment: .leading, spacing: 0) {
                Text(pulse.map(String.init) ?? "--")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Pulse").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pulse.map { "Pulse \($0)" } ?? "No pulse reading")
    }
}

/// Signal strength from the perfusion index, as four bars.
struct SignalBars: View {
    let perfusionIndex: Double?
    let minimum: Double

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < bars ? color : Color.secondary.opacity(0.3))
                        .frame(width: 5, height: CGFloat(8 + index * 5))
                }
            }
            .frame(height: 24, alignment: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("Signal").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(label)")
    }

    private var bars: Int {
        guard let pi = perfusionIndex else { return 0 }
        if pi < minimum { return 1 }
        if pi < 1 { return 2 }
        if pi < 3 { return 3 }
        return 4
    }

    private var label: String {
        switch bars {
        case 0: return "None"
        case 1: return "Weak"
        case 2: return "OK"
        default: return "Good"
        }
    }

    private var color: Color { bars <= 1 ? Theme.caution : Theme.good }
}

/// Initials in a circle, for contacts.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.15), in: Circle())
            .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: - Formatting

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

    static func names(_ names: [String]) -> String {
        names.isEmpty ? "your contacts" : ListFormatter.localizedString(byJoining: names)
    }
}
