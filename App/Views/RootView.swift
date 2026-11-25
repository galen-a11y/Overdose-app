import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var session: SessionManager

    var body: some View {
        Group {
            if !store.data.onboardingComplete {
                OnboardingView()
            } else {
                switch session.phase {
                case .idle:
                    HomeView()
                case let .finished(summary):
                    SessionSummaryView(summary: summary)
                case .starting, .monitoring:
                    MonitoringView()
                case let .checkIn(reason, deadline):
                    CheckInView(reason: reason, deadline: deadline)
                case let .alerted(reason):
                    AlertedView(reason: reason)
                }
            }
        }
        .animation(.default, value: session.phase)
    }
}
