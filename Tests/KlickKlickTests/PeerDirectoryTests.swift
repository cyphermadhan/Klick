import XCTest
@testable import KlickKlick

/// Unit coverage for the PeerDirectory merge logic. PeerDirectory is
/// main-actor bound because it feeds the UI, so every test hops there
/// explicitly before touching it.
@MainActor
final class PeerDirectoryTests: XCTestCase {

    func testWifiOnly() {
        let dir = PeerDirectory()
        dir.update([
            PeerInfo(name: "bravo", transport: .wifi),
            PeerInfo(name: "alpha", transport: .wifi),
        ], from: .wifi)

        XCTAssertEqual(dir.peers.map(\.name), ["bravo", "alpha"])
        // Directory preserves the order the transport provides — UDPTransport
        // already sorts alphabetically, so the caller shouldn't re-sort.
        XCTAssertTrue(dir.peers.allSatisfy { $0.transport == .wifi })
    }

    func testNearbyOnly() {
        let dir = PeerDirectory()
        dir.update([
            PeerInfo(name: "charlie", transport: .nearby),
        ], from: .nearby)

        XCTAssertEqual(dir.peers.count, 1)
        XCTAssertEqual(dir.peers.first?.transport, .nearby)
    }

    func testBothTransports_wifiAppearsFirst() {
        let dir = PeerDirectory()
        dir.update([PeerInfo(name: "charlie", transport: .nearby)], from: .nearby)
        dir.update([PeerInfo(name: "alpha",   transport: .wifi)],   from: .wifi)

        // Regardless of insertion order, wifi bucket comes before nearby bucket.
        XCTAssertEqual(dir.peers.map(\.name), ["alpha", "charlie"])
        XCTAssertEqual(dir.peers.map(\.transport), [.wifi, .nearby])
    }

    func testSameNameOnBothTransports_producesTwoRows() {
        // Phase 1 chose NOT to collapse same-name peers. Both entries show
        // so the user picks which link to send on. Verify that here so the
        // behavior doesn't silently regress when the collapse feature lands.
        let dir = PeerDirectory()
        dir.update([PeerInfo(name: "madhan", transport: .wifi)],   from: .wifi)
        dir.update([PeerInfo(name: "madhan", transport: .nearby)], from: .nearby)

        XCTAssertEqual(dir.peers.count, 2)
        XCTAssertEqual(Set(dir.peers.map(\.transport)), [.wifi, .nearby])
        // IDs must still be distinct or SwiftUI's ForEach will collapse them
        // at the view layer (the bug we're guarding against).
        XCTAssertEqual(Set(dir.peers.map(\.id)).count, 2)
    }

    func testReplacementUpdates_dontAffectOtherTransport() {
        let dir = PeerDirectory()
        dir.update([PeerInfo(name: "alpha", transport: .wifi)], from: .wifi)
        dir.update([PeerInfo(name: "bravo", transport: .nearby)], from: .nearby)

        // Refreshing wifi (peer dropped) must NOT wipe the nearby peer.
        dir.update([], from: .wifi)
        XCTAssertEqual(dir.peers.map(\.name), ["bravo"])
        XCTAssertEqual(dir.peers.map(\.transport), [.nearby])
    }

    func testClearRemovesEverything() {
        let dir = PeerDirectory()
        dir.update([PeerInfo(name: "alpha", transport: .wifi)],   from: .wifi)
        dir.update([PeerInfo(name: "bravo", transport: .nearby)], from: .nearby)
        XCTAssertEqual(dir.peers.count, 2)

        dir.clear()
        XCTAssertTrue(dir.peers.isEmpty)
    }

    func testRangeModeIncludesFlags() {
        XCTAssertTrue(RangeMode.wifi.includesWifi)
        XCTAssertFalse(RangeMode.wifi.includesNearby)

        XCTAssertTrue(RangeMode.nearby.includesNearby)
        XCTAssertFalse(RangeMode.nearby.includesWifi)

        XCTAssertTrue(RangeMode.both.includesWifi)
        XCTAssertTrue(RangeMode.both.includesNearby)
    }

    func testPeerTransportTags() {
        XCTAssertEqual(PeerTransport.wifi.tag,   "WIFI")
        XCTAssertEqual(PeerTransport.nearby.tag, "NEAR")
    }

    func testPeerInfoId_isTransportScoped() {
        // Same display name on two transports must hash to distinct
        // identifiers — otherwise SwiftUI collapses the rows and Set
        // membership gives the wrong answer in PeerDirectory's rebuild.
        let wifi   = PeerInfo(name: "madhan", transport: .wifi)
        let nearby = PeerInfo(name: "madhan", transport: .nearby)
        XCTAssertNotEqual(wifi.id, nearby.id)
        XCTAssertNotEqual(wifi, nearby)
    }
}
