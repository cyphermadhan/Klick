import XCTest
@testable import KlickKlick

@MainActor
final class LoRaBridgeTests: XCTestCase {
    private var link: FakeMeshtasticLink!
    private var codec: StubMeshtasticCodec!
    private var bridge: LoRaBridge!
    private var defaults: UserDefaults!
    private var ledger: DutyCycleLedger!
    private var peer: PeerInfo!
    private let suite = "klick.tests.lora"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        ledger = DutyCycleLedger(defaults: defaults, storageKey: "ledger")
        link = FakeMeshtasticLink(startsConnected: false)
        codec = StubMeshtasticCodec()
        bridge = LoRaBridge(link: link, codec: codec, ledger: ledger, region: .us)
        peer = PeerInfo(name: "RADIO", transport: .mesh, endpoint: nil)
        try bridge.start(advertisingAs: "UNIT-TEST")
    }

    override func tearDown() async throws {
        bridge.stop()
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    // MARK: - Gating

    func testSendTextReturnsNilWhenLinkDisconnected() {
        XCTAssertFalse(link.isConnected)
        let seq = bridge.sendText(.chatText, payload: Data("hi".utf8), nonce: Packet.zeroNonce(), to: peer)
        XCTAssertNil(seq)
        XCTAssertTrue(link.writtenFrames.isEmpty)
    }

    func testSendTextWritesWhenConnected() throws {
        link.simulateConnectedChange(true)
        let seq = bridge.sendText(.chatText, payload: Data("hi".utf8), nonce: Packet.zeroNonce(), to: peer)
        XCTAssertNotNil(seq)
        XCTAssertEqual(link.writtenFrames.count, 1)
        // Stub codec is passthrough, so the frame should decode as our Packet.
        let decoded = try Packet.decode(link.writtenFrames[0])
        XCTAssertEqual(decoded.type, .chatText)
        XCTAssertEqual(decoded.sequence, seq)
    }

    func testSendAudioIsRefused() {
        link.simulateConnectedChange(true)
        bridge.sendAudio(opusPayload: Data(repeating: 0, count: 40),
                        nonce: Packet.zeroNonce(), to: peer)
        XCTAssertTrue(link.writtenFrames.isEmpty, "Voice must not be written to the LoRa link")
    }

    func testIgnoresPeersFromOtherTransports() {
        link.simulateConnectedChange(true)
        let wifiPeer = PeerInfo(name: "X", transport: .wifi, endpoint: nil)
        let seq = bridge.sendText(.chatText, payload: Data("hi".utf8),
                                  nonce: Packet.zeroNonce(), to: wifiPeer)
        XCTAssertNil(seq)
    }

    // MARK: - Duty-cycle

    func testDutyCycleBlocksEUSendWhenBudgetExhausted() {
        // Swap bridge for an EU one against the same link + ledger.
        bridge.stop()
        ledger.record(durationMs: 36_000) // EU budget is 36s; fully spent.
        bridge = LoRaBridge(link: link, codec: codec, ledger: ledger, region: .eu)
        try? bridge.start(advertisingAs: "EU-TEST")
        link.simulateConnectedChange(true)

        let seq = bridge.sendText(.chatText, payload: Data("hi".utf8),
                                  nonce: Packet.zeroNonce(), to: peer)
        XCTAssertNil(seq, "Exhausted budget should block the send")
        XCTAssertTrue(link.writtenFrames.isEmpty)
    }

    func testUSSendIgnoresDutyCycleLedger() {
        // US region has no cap; even with a pretend-exhausted ledger the
        // send should go through.
        ledger.record(durationMs: 1_000_000)
        link.simulateConnectedChange(true)
        let seq = bridge.sendText(.chatText, payload: Data("hi".utf8),
                                  nonce: Packet.zeroNonce(), to: peer)
        XCTAssertNotNil(seq)
    }

    // MARK: - Peer announcement

    func testConnectionChangeTogglesAdvertisedPeer() {
        // Box the mutable capture in a class so it can be shared with the
        // @Sendable callback without tripping strict-concurrency rules.
        final class Box: @unchecked Sendable { var peers: [PeerInfo] = [] }
        let box = Box()
        bridge.onPeersChanged = { box.peers = $0 }
        link.simulateConnectedChange(true)
        XCTAssertEqual(box.peers.count, 1)
        XCTAssertEqual(box.peers.first?.transport, .mesh)
        link.simulateConnectedChange(false)
        XCTAssertEqual(box.peers.count, 0)
    }

    // MARK: - Inbound

    func testInboundFrameDeliversDecodedPacket() {
        final class Box: @unchecked Sendable { var received: Packet? }
        let box = Box()
        bridge.onReceive = { box.received = $0 }

        // Build a Packet-on-the-wire, then feed it through the link (stub
        // codec means the mesh "frame" is just our encode() bytes).
        let original = Packet(
            type: .chatText,
            sequence: 77,
            timestampMs: 0,
            nonce: Packet.zeroNonce(),
            payload: Data("ping".utf8)
        )
        link.simulateInbound(original.encode())
        XCTAssertEqual(box.received?.sequence, 77)
        XCTAssertEqual(box.received?.type, .chatText)
    }
}
