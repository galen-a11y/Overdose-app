import Foundation

/// A queue of server requests that must not be lost when the phone has no
/// signal. Alerts, check-ins and "I'm safe" texts wait here and are retried with
/// backoff until the server accepts them. Heartbeats are never queued: a stale
/// heartbeat is worthless, and the next one replaces it.
public struct Outbox: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// Path relative to the server base URL, for example "v1/sessions/abc/alert".
        public var path: String
        public var body: Data
        /// Session token sent as `Authorization: Bearer`, if the route needs one.
        public var token: String?
        public var createdAt: Date
        public var attempts: Int
        public var nextAttemptAt: Date

        public init(id: UUID = UUID(), path: String, body: Data, token: String? = nil, createdAt: Date) {
            self.id = id
            self.path = path
            self.body = body
            self.token = token
            self.createdAt = createdAt
            self.attempts = 0
            self.nextAttemptAt = createdAt
        }
    }

    public private(set) var entries: [Entry] = []

    /// Requests older than this are dropped; the server will have already sent
    /// its own lost-contact text by then.
    public static let maximumAge: TimeInterval = 6 * 60 * 60
    public static let maximumBackoff: TimeInterval = 30

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    @discardableResult
    public mutating func enqueue(path: String, body: Data, token: String? = nil, at now: Date) -> Entry {
        let entry = Entry(path: path, body: body, token: token, createdAt: now)
        entries.append(entry)
        return entry
    }

    /// Entries ready to send, oldest first so texts arrive in the order they happened.
    public mutating func due(at now: Date) -> [Entry] {
        entries.removeAll { now.timeIntervalSince($0.createdAt) > Self.maximumAge }
        return entries.filter { $0.nextAttemptAt <= now }
    }

    public mutating func markSent(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Backs off 2, 4, 8, 16, then 30 seconds between tries.
    public mutating func markFailed(_ id: UUID, at now: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].attempts += 1
        let delay = min(Self.maximumBackoff, pow(2, Double(entries[index].attempts)))
        entries[index].nextAttemptAt = now.addingTimeInterval(delay)
    }

    /// Fills in a session placeholder once the server session exists, for
    /// requests queued while the phone was offline at session start.
    public mutating func resolve(placeholder: String, with value: String, token: String) {
        for index in entries.indices where entries[index].path.contains(placeholder) {
            entries[index].path = entries[index].path.replacingOccurrences(of: placeholder, with: value)
            entries[index].token = token
        }
    }

    /// Drops entries still waiting on a placeholder that will never be filled.
    public mutating func removeUnresolved(placeholder: String) {
        entries.removeAll { $0.path.contains(placeholder) }
    }

    /// Drops everything for a session, for example once it has ended on the server.
    public mutating func removeAll(pathPrefix: String) {
        entries.removeAll { $0.path.hasPrefix(pathPrefix) }
    }
}
