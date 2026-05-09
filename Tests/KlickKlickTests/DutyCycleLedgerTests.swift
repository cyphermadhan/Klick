import XCTest
@testable import KlickKlick

final class DutyCycleLedgerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "klick.tests.ledger"

    override func setUp() {
        super.setUp()
        // Isolated suite per test method so parallel execution doesn't
        // leak entries across tests, and so the real user's ledger stays
        // untouched.
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeLedger() -> DutyCycleLedger {
        DutyCycleLedger(defaults: defaults, storageKey: "ledger")
    }

    // MARK: - Fresh ledger

    func testFreshLedgerStartsEmpty() {
        let ledger = makeLedger()
        XCTAssertEqual(ledger.usedMs(), 0)
        XCTAssertTrue(ledger.canTransmit(durationMs: 1_000, dutyCycle: 0.01))
    }

    func testEUBudgetIs36000Ms() {
        // 1 hour × 1 % = 36 s on air. If this number changes, check the
        // regulator didn't relax ETSI EN 300 220 overnight.
        let ledger = makeLedger()
        XCTAssertEqual(ledger.remainingMs(dutyCycle: 0.01), 36_000)
    }

    // MARK: - Recording + budget arithmetic

    func testRecordingDecrementsRemaining() {
        let ledger = makeLedger()
        ledger.record(durationMs: 10_000)
        XCTAssertEqual(ledger.usedMs(), 10_000)
        XCTAssertEqual(ledger.remainingMs(dutyCycle: 0.01), 26_000)
    }

    func testCannotTransmitWhenBudgetExhausted() {
        let ledger = makeLedger()
        ledger.record(durationMs: 35_000)
        XCTAssertTrue(ledger.canTransmit(durationMs: 1_000, dutyCycle: 0.01))
        XCTAssertFalse(ledger.canTransmit(durationMs: 2_000, dutyCycle: 0.01))
    }

    func testFractionUsedRangesZeroToOne() {
        let ledger = makeLedger()
        XCTAssertEqual(ledger.fractionUsed(dutyCycle: 0.01), 0.0, accuracy: 0.001)
        ledger.record(durationMs: 18_000) // half the budget
        XCTAssertEqual(ledger.fractionUsed(dutyCycle: 0.01), 0.5, accuracy: 0.001)
    }

    // MARK: - Rolling window

    func testOldEntriesAgeOut() {
        let ledger = makeLedger()
        let twoHoursAgo = Date().addingTimeInterval(-7_200)
        ledger.record(durationMs: 30_000, at: twoHoursAgo)
        // usedMs() triggers a prune, old entry should be gone.
        XCTAssertEqual(ledger.usedMs(), 0)
    }

    func testRecentEntriesStillCount() {
        let ledger = makeLedger()
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        ledger.record(durationMs: 5_000, at: tenMinutesAgo)
        XCTAssertEqual(ledger.usedMs(), 5_000)
    }

    // MARK: - Persistence

    func testLedgerRoundtripsThroughUserDefaults() {
        let first = makeLedger()
        first.record(durationMs: 12_000)
        // A fresh instance pointed at the same store should see the entry.
        let second = makeLedger()
        XCTAssertEqual(second.usedMs(), 12_000)
    }

    func testResetClearsPersistedState() {
        let first = makeLedger()
        first.record(durationMs: 12_000)
        first.reset()
        let second = makeLedger()
        XCTAssertEqual(second.usedMs(), 0)
    }
}
