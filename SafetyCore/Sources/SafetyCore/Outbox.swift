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
        public var createdAt: Date
        public var attempts: Int
        public var nextAttemptAt: Date

        public init(id: UUID = UUID(), path: String, body: Data, createdAt: Date) {
            self.id = id
            self.path = path
            self.body = body
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

    public mutating func enqueue(path: String, body: Data, at now: Date) -> Entry {
        let entry = Entry(path: path, body: body, createdAt: now)
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

    /// Drops everything for a session, for example once it has ended on the server.
    public mutating func removeAll(pathPrefix: String) {
        entries.removeAll { $0.path.hasPrefix(pathPrefix) }
    }
}
