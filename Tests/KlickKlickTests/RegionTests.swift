import XCTest
@testable import KlickKlick

final class RegionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Isolate from other tests that might flip the store.
        RegionStore.reset()
    }

    override func tearDown() {
        RegionStore.reset()
        super.tearDown()
    }

    // MARK: - Locale mapping

    func testUSLocaleMapsToUS() {
        XCTAssertEqual(Region.fromLocaleCode("US"), .us)
        XCTAssertEqual(Region.fromLocaleCode("us"), .us)
    }

    func testIndiaLocaleMapsToIN() {
        XCTAssertEqual(Region.fromLocaleCode("IN"), .in_)
    }

    func testEuropeanLocalesMapToEU() {
        XCTAssertEqual(Region.fromLocaleCode("DE"), .eu)
        XCTAssertEqual(Region.fromLocaleCode("FR"), .eu)
        XCTAssertEqual(Region.fromLocaleCode("GB"), .eu)
        XCTAssertEqual(Region.fromLocaleCode("CH"), .eu)
    }

    func testOceaniaMapsToAU() {
        XCTAssertEqual(Region.fromLocaleCode("AU"), .au)
        XCTAssertEqual(Region.fromLocaleCode("NZ"), .au)
    }

    func testUnknownLocaleFallsBackToOther() {
        XCTAssertEqual(Region.fromLocaleCode("ZZ"), .other)
        XCTAssertEqual(Region.fromLocaleCode(nil), .other)
    }

    // MARK: - Regulatory rules

    func testEUHasOnePercentDutyCycle() {
        XCTAssertEqual(Region.eu.dutyCycle, 0.01)
    }

    func testOtherRegionsHaveNoDutyCycleCap() {
        XCTAssertNil(Region.us.dutyCycle)
        XCTAssertNil(Region.in_.dutyCycle)
        XCTAssertNil(Region.au.dutyCycle)
    }

    func testEUHasLowerMaxPowerThanUS() {
        // Regulatory reality check: EU's 14 dBm (25 mW) is much lower than
        // the US / India 30 dBm (1 W) allowance. If this flips, the copy in
        // RadioView is lying.
        XCTAssertLessThan(Region.eu.maxPowerDbm, Region.us.maxPowerDbm)
        XCTAssertLessThan(Region.eu.maxPowerDbm, Region.in_.maxPowerDbm)
    }

    func testMeshtasticPresetMatchesExpected() {
        // These exact strings are what Meshtastic firmware reports over
        // the admin channel — the pair-time region guard compares against
        // these, so a typo here silently breaks the mismatch warning.
        XCTAssertEqual(Region.us.meshtasticPreset, "US")
        XCTAssertEqual(Region.eu.meshtasticPreset, "EU_868")
        XCTAssertEqual(Region.in_.meshtasticPreset, "IN_865")
    }

    // MARK: - Persistence

    func testCurrentDefaultsToLocaleWhenUnset() {
        XCTAssertEqual(RegionStore.current, Region.localeDefault)
        XCTAssertFalse(RegionStore.isUserOverridden)
    }

    func testSettingCurrentPersistsAndFlagsOverride() {
        RegionStore.current = .eu
        XCTAssertEqual(RegionStore.current, .eu)
        XCTAssertTrue(RegionStore.isUserOverridden)
    }

    func testResetRevertsToLocaleDefault() {
        RegionStore.current = .in_
        RegionStore.reset()
        XCTAssertEqual(RegionStore.current, Region.localeDefault)
        XCTAssertFalse(RegionStore.isUserOverridden)
    }
}
