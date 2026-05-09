import XCTest
@testable import KlickKlick

@MainActor
final class MessageDeliveryTrackerTests: XCTestCase {
    func testRecordStartsInSendingState() {
        let tracker = MessageDeliveryTracker()
        let id = UUID()
        tracker.record(seq: 1, entryId: id)
        XCTAssertEqual(tracker.state(seq: 1), .sending)
        XCTAssertEqual(tracker.state(entryId: id), .sending)
    }

    func testAcknowledgeFlipsToDelivered() {
        let tracker = MessageDeliveryTracker()
        tracker.record(seq: 42, entryId: UUID())
        tracker.acknowledge(seq: 42)
        XCTAssertEqual(tracker.state(seq: 42), .delivered)
    }

    func testAcknowledgeUnknownSeqIsNoOp() {
        // Ack arriving after we'd already forgotten about the seq (e.g.
        // session restart, then a stale mesh delivery notification) is
        // harmless — no crash, no spurious state.
        let tracker = MessageDeliveryTracker()
        tracker.acknowledge(seq: 99) // never recorded
        XCTAssertNil(tracker.state(seq: 99))
    }

    func testMarkFailedFlipsToFailed() {
        let tracker = MessageDeliveryTracker()
        tracker.record(seq: 7, entryId: UUID())
        tracker.markFailed(seq: 7)
        XCTAssertEqual(tracker.state(seq: 7), .failed)
    }

    func testTimeoutFiresWhenNoAckArrives() async {
        let tracker = MessageDeliveryTracker()
        let id = UUID()
        tracker.record(seq: 5, entryId: id, timeout: .milliseconds(50))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(tracker.state(seq: 5), .timedOut)
    }

    func testAckBeatsTimeout() async {
        // Ack arrives within the window → should stay .delivered even
        // after the timeout deadline passes.
        let tracker = MessageDeliveryTracker()
        tracker.record(seq: 6, entryId: UUID(), timeout: .milliseconds(100))
        try? await Task.sleep(for: .milliseconds(30))
        tracker.acknowledge(seq: 6)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(tracker.state(seq: 6), .delivered)
    }

    func testResetClearsAllEntries() {
        let tracker = MessageDeliveryTracker()
        tracker.record(seq: 1, entryId: UUID())
        tracker.record(seq: 2, entryId: UUID())
        tracker.reset()
        XCTAssertNil(tracker.state(seq: 1))
        XCTAssertNil(tracker.state(seq: 2))
    }

    func testStateVersionBumpsOnEveryChange() {
        let tracker = MessageDeliveryTracker()
        let v0 = tracker.stateVersion
        tracker.record(seq: 1, entryId: UUID())
        XCTAssertNotEqual(tracker.stateVersion, v0)
        let v1 = tracker.stateVersion
        tracker.acknowledge(seq: 1)
        XCTAssertNotEqual(tracker.stateVersion, v1)
    }
}
