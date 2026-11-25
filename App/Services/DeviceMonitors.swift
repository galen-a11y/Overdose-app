import Combine
import Foundation
import Network
import UIKit

/// Phone battery level and charging state.
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Float = 1
    @Published private(set) var isCharging = false

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        update()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.update()
            })
        }
    }

    private var observers: [NSObjectProtocol] = []

    /// Percent, or `nil` when unknown (the simulator reports -1).
    var percent: Int? { level < 0 ? nil : Int((level * 100).rounded()) }

    var isLowForStart: Bool { (percent ?? 100) < 20 && !isCharging }
    var isAboutToDie: Bool { (percent ?? 100) <= 5 && !isCharging }

    private func update() {
        let device = UIDevice.current
        DispatchQueue.main.async {
            self.level = device.batteryLevel
            self.isCharging = device.batteryState == .charging || device.batteryState == .full
        }
    }
}

/// Whether the phone has a usable internet connection.
final class ConnectivityMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "spotter.connectivity"))
    }
}
