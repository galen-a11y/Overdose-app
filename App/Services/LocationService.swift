import Combine
import CoreLocation
import Foundation

/// Keeps a recent location during a session so an alert always has one.
///
/// Updates run in the background (the `location` background mode) for the
/// whole session. That also keeps the app running with the screen locked,
/// so the alert engine's timers keep ticking. iOS shows the blue location
/// indicator while this is on, which is the honest signal that Spotter is watching.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var isRunning = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    var isAllowed: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestPermission() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func startSession() {
        guard !isRunning else { return }
        isRunning = true
        requestPermission()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    func stopSession() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    /// The best location we have, as long as it's from this session or recent.
    var forAlert: CLLocation? {
        guard let latest, latest.horizontalAccuracy >= 0 else { return nil }
        return latest
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isRunning, isAllowed {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        // Keep a more accurate fix over a slightly newer but much worse one.
        if let current = latest,
           newest.timestamp.timeIntervalSince(current.timestamp) < 60,
           newest.horizontalAccuracy > current.horizontalAccuracy * 3 {
            return
        }
        latest = newest
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (no fix yet) are normal indoors; keep the last fix.
        NSLog("Spotter: location error \(error.localizedDescription)")
    }
}
