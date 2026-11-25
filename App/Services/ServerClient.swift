import CoreLocation
import Foundation
import SafetyCore

/// Talks to the Spotter server (server/ in this repo). The server sends every
/// text, because an iPhone app can't send one without the person tapping Send.
final class ServerClient {
    enum ServerError: LocalizedError {
        case notConfigured
        case http(Int, String?)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "The text-message server isn't set up in this build."
            case let .http(code, message): return message ?? "The server answered with error \(code)."
            case .badResponse: return "The server sent an unexpected answer."
            }
        }
    }

    struct SetupResult: Identifiable {
        var id: String { phone }
        let phone: String
        let sent: Bool
        let error: String?
    }

    let baseURL: URL?
    private let appKey: String
    private let session: URLSession

    init(bundle: Bundle = .main) {
        let raw = (bundle.object(forInfoDictionaryKey: "SpotterServerURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        baseURL = raw.hasPrefix("https://") || raw.hasPrefix("http://") ? URL(string: raw) : nil
        appKey = bundle.object(forInfoDictionaryKey: "SpotterAppKey") as? String ?? ""
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    var isConfigured: Bool { baseURL != nil }

    // MARK: - Setup texts

    func sendWelcome(firstName: String, contact: EmergencyContact) async throws {
        _ = try await post("v1/welcome", body: [
            "firstName": firstName,
            "contact": ["name": contact.name, "phone": contact.phone],
        ])
    }

    func sendTest(firstName: String, contacts: [EmergencyContact]) async throws -> [SetupResult] {
        let json = try await post("v1/test", body: [
            "firstName": firstName,
            "contacts": contacts.map { ["name": $0.name, "phone": $0.phone] },
        ])
        let results = json["results"] as? [[String: Any]] ?? []
        return results.map {
            SetupResult(phone: $0["phone"] as? String ?? "", sent: $0["sent"] as? Bool ?? false, error: $0["error"] as? String)
        }
    }

    // MARK: - Sessions

    func createSession(firstName: String, contacts: [EmergencyContact], plannedDuration: TimeInterval?, location: CLLocation?) async throws -> (id: String, token: String) {
        var body: [String: Any] = [
            "firstName": firstName,
            "contacts": contacts.map { ["name": $0.name, "phone": $0.phone] },
            "timeZone": TimeZone.current.identifier,
            "heartbeatTimeoutSec": 120,
        ]
        if let plannedDuration { body["plannedDurationSec"] = Int(plannedDuration) }
        if let location { body["location"] = Self.json(location) }
        let json = try await post("v1/sessions", body: body)
        guard let id = json["sessionId"] as? String, let token = json["token"] as? String else { throw ServerError.badResponse }
        return (id, token)
    }

    /// Sends a raw request. Used by the outbox and for heartbeats.
    func send(path: String, body: Data, token: String?) async throws {
        _ = try await post(path, bodyData: body, token: token)
    }

    // MARK: - Helpers

    static func json(_ location: CLLocation) -> [String: Any] {
        [
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "at": Int(location.timestamp.timeIntervalSince1970 * 1000),
        ]
    }

    static func encode(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any], token: String? = nil) async throws -> [String: Any] {
        try await post(path, bodyData: Self.encode(body), token: token)
    }

    private func post(_ path: String, bodyData: Data, token: String?) async throws -> [String: Any] {
        guard let baseURL else { throw ServerError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !appKey.isEmpty { request.setValue(appKey, forHTTPHeaderField: "X-App-Key") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw ServerError.http(http.statusCode, json["error"] as? String)
        }
        return json
    }
}

extension ServerClient.ServerError {
    /// 4xx errors other than 408/429 won't succeed on retry (bad input, session gone).
    var isPermanent: Bool {
        if case let .http(code, _) = self { return (400..<500).contains(code) && code != 408 && code != 429 }
        return self == .notConfigured
    }
}

extension ServerClient.ServerError: Equatable {}
