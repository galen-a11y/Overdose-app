import XCTest
@testable import SafetyCore

final class PC60FWDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func measurement(spo2: UInt8, pr: UInt16, pi: UInt8, status: UInt8 = 0) -> Data {
        PC60FWDecoder.encode(
            token: 0x0F, type: 0x01,
            content: [spo2, UInt8(pr & 0xFF), UInt8(pr >> 8), pi, status, 0xC0]
        )
    }

    func testCRCMatchesViatomTable() {
        // First entries of Table_CRC8_PC in Viatom's SDK: 0x00, 0x5E, 0xBC, 0xE2.
        XCTAssertEqual(PC60FWDecoder.crc8Maxim([0x00]), 0x00)
        XCTAssertEqual(PC60FWDecoder.crc8Maxim([0x01]), 0x5E)
        XCTAssertEqual(PC60FWDecoder.crc8Maxim([0x02]), 0xBC)
        XCTAssertEqual(PC60FWDecoder.crc8Maxim([0x03]), 0xE2)
        // Standard CRC-8/Maxim check value.
        XCTAssertEqual(PC60FWDecoder.crc8Maxim(Array("123456789".utf8)), 0xA1)
    }

    func testDecodesMeasurementFromCommunityExample() {
        // Payload from the community decoder README: SpO2 0x60 (96), PR 0x3e (62), PI 0x50 (8.0).
        var decoder = PC60FWDecoder()
        let frames = decoder.feed(measurement(spo2: 0x60, pr: 0x3E, pi: 0x50))
        XCTAssertEqual(frames, [.measurement(spo2: 96, pulseRate: 62, perfusionIndex: 8.0, probeOff: false, searching: false)])
        XCTAssertEqual(frames.first?.reading(at: now), PulseReading(spo2: 96, pulseRate: 62, perfusionIndex: 8.0, timestamp: now))
    }

    func testPulseRateIsLittleEndian() {
        var decoder = PC60FWDecoder()
        let frames = decoder.feed(measurement(spo2: 95, pr: 0x0102, pi: 20))
        guard case let .measurement(_, pulseRate, _, _, _) = frames.first else { return XCTFail("no frame") }
        XCTAssertEqual(pulseRate, 258)
    }

    func testProbeOffBecomesEmptyReading() {
        var decoder = PC60FWDecoder()
        let frames = decoder.feed(measurement(spo2: 98, pr: 70, pi: 30, status: 0x02))
        let reading = frames.first?.reading(at: now)
        XCTAssertNotNil(reading)
        XCTAssertNil(reading?.spo2)
        XCTAssertEqual(reading?.quality(minimumPerfusionIndex: 0.3), .noData)
    }

    func testSearchingAndZeroValuesBecomeEmptyReadings() {
        var decoder = PC60FWDecoder()
        let searching = decoder.feed(measurement(spo2: 98, pr: 70, pi: 30, status: 0x04)).first?.reading(at: now)
        let zero = decoder.feed(measurement(spo2: 0, pr: 0, pi: 0)).first?.reading(at: now)
        XCTAssertNil(searching?.spo2)
        XCTAssertNil(zero?.spo2)
    }

    func testHandlesFramesSplitAcrossNotifications() {
        var decoder = PC60FWDecoder()
        let bytes = measurement(spo2: 97, pr: 72, pi: 40)
        XCTAssertTrue(decoder.feed(bytes.prefix(3)).isEmpty)
        XCTAssertTrue(decoder.feed(bytes.dropFirst(3).prefix(4)).isEmpty)
        XCTAssertEqual(decoder.feed(bytes.dropFirst(7)).count, 1)
    }

    func testHandlesSeveralFramesInOneNotification() {
        var decoder = PC60FWDecoder()
        var data = measurement(spo2: 97, pr: 72, pi: 40)
        data.append(PC60FWDecoder.encode(token: 0x0F, type: 0x02, content: [0x3B, 0x38, 0xB5, 0x32, 0x2F]))
        data.append(PC60FWDecoder.encode(token: 0xF0, type: 0x03, content: [0x02]))
        let frames = decoder.feed(data)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames[1], .waveform([0x3B, 0x38, 0x35, 0x32, 0x2F]))
        XCTAssertEqual(frames[2], .battery(level: 2))
    }

    func testResyncsAfterGarbageAndBadChecksum() {
        var decoder = PC60FWDecoder()
        var corrupt = measurement(spo2: 50, pr: 72, pi: 40)
        corrupt[corrupt.count - 1] ^= 0xFF
        var data = Data([0x00, 0x13, 0xAA, 0x00])
        data.append(corrupt)
        data.append(measurement(spo2: 97, pr: 72, pi: 40))
        let frames = decoder.feed(data)
        XCTAssertEqual(frames, [.measurement(spo2: 97, pulseRate: 72, perfusionIndex: 4.0, probeOff: false, searching: false)])
        XCTAssertEqual(decoder.checksumFailures, 1)
    }

    func testWorkingStatusFrame() {
        var decoder = PC60FWDecoder()
        let frames = decoder.feed(PC60FWDecoder.encode(token: 0x0F, type: 0x21, content: [0x02, 0x02, 0x00, 0x00]))
        XCTAssertEqual(frames, [.workingStatus(mode: 2, step: 2)])
    }

    func testJunkNeverGrowsBufferForever() {
        var decoder = PC60FWDecoder()
        for _ in 0..<100 { _ = decoder.feed(Data(repeating: 0xAA, count: 100)) }
        XCTAssertEqual(decoder.feed(measurement(spo2: 97, pr: 72, pi: 40)).count, 1)
    }
}
