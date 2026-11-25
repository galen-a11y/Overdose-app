import XCTest
@testable import SafetyCore

final class PhoneNumberTests: XCTestCase {
    func testNormalizesUSNumbers() {
        XCTAssertEqual(PhoneNumber.normalize("(503) 555-0123"), "+15035550123")
        XCTAssertEqual(PhoneNumber.normalize("1 503 555 0123"), "+15035550123")
        XCTAssertEqual(PhoneNumber.normalize("+1 503-555-0123"), "+15035550123")
        XCTAssertEqual(PhoneNumber.normalize("+44 20 7946 0958"), "+442079460958")
    }

    func testRejectsImpossibleNumbers() {
        XCTAssertNil(PhoneNumber.normalize("555-0123"))
        XCTAssertNil(PhoneNumber.normalize("(103) 555-0123"))
        XCTAssertNil(PhoneNumber.normalize(""))
        XCTAssertNil(PhoneNumber.normalize("+0123456789"))
    }

    func testDisplay() {
        XCTAssertEqual(PhoneNumber.display("+15035550123"), "(503) 555-0123")
        XCTAssertEqual(PhoneNumber.display("+442079460958"), "+442079460958")
    }
}

final class OutboxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    func testRetriesWithBackoffAndKeepsOrder() {
        var outbox = Outbox()
        let a = outbox.enqueue(path: "v1/a", body: Data(), at: t0)
        let b = outbox.enqueue(path: "v1/b", body: Data(), at: t0)
        XCTAssertEqual(outbox.due(at: t0).map(\.id), [a.id, b.id])

        outbox.markFailed(a.id, at: t0)
        XCTAssertEqual(outbox.due(at: t0.addingTimeInterval(1)).map(\.id), [b.id])
        XCTAssertEqual(outbox.due(at: t0.addingTimeInterval(2)).map(\.id), [a.id, b.id])

        for _ in 0..<10 { outbox.markFailed(a.id, at: t0) }
        XCTAssertEqual(outbox.entries.first?.nextAttemptAt, t0.addingTimeInterval(30))

        outbox.markSent(b.id)
        XCTAssertEqual(outbox.entries.map(\.id), [a.id])
    }

    func testResolvesSessionPlaceholder() {
        var outbox = Outbox()
        outbox.enqueue(path: "v1/sessions/{session}/alert", body: Data(), at: t0)
        outbox.enqueue(path: "v1/test", body: Data(), at: t0)
        outbox.resolve(placeholder: "{session}", with: "abc", token: "tok")
        XCTAssertEqual(outbox.entries.map(\.path), ["v1/sessions/abc/alert", "v1/test"])
        XCTAssertEqual(outbox.entries.map(\.token), ["tok", nil])
    }

    func testDropsVeryOldEntries() {
        var outbox = Outbox()
        _ = outbox.enqueue(path: "v1/a", body: Data(), at: t0)
        XCTAssertTrue(outbox.due(at: t0.addingTimeInterval(7 * 3600)).isEmpty)
        XCTAssertTrue(outbox.isEmpty)
    }
}

final class ScenarioTests: XCTestCase {
    func testFingerOutGoesSilent() {
        let now = Date()
        XCTAssertNotNil(SensorScenario.fingerOut.reading(elapsed: 12, at: now))
        XCTAssertNil(SensorScenario.fingerOut.reading(elapsed: 12, at: now)?.spo2)
        XCTAssertNil(SensorScenario.fingerOut.reading(elapsed: 20, at: now))
    }
}
