import XCTest
import Network
@testable import KlickKlick

final class UDPTransportTests: XCTestCase {

    /// Regression test for the "only first packet received" bug. A UDP
    /// `receiveMessage` completion always reports `isComplete = true` for
    /// each datagram — if the listener treats that as end-of-stream and
    /// stops re-arming, audio cuts out after packet #1. This test sends
    /// several datagrams in a row and asserts we see them all.
    func testLocalhostMultiplePacketsReceived() throws {
        let sender = UDPTransport()
        let receiver = UDPTransport()
        try sender.start(advertisingAs: "test-sender")
        try receiver.start(advertisingAs: "test-receiver")

        let bound = expectation(description: "listeners bound")
        Task {
            for _ in 0..<50 where sender.localPort == nil || receiver.localPort == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            bound.fulfill()
        }
        wait(for: [bound], timeout: 5)

        guard let receiverPort = receiver.localPort else {
            return XCTFail("Receiver failed to bind a port")
        }

        let expectedCount = 5
        let received = expectation(description: "received all packets")
        received.expectedFulfillmentCount = expectedCount

        // Reference-type box so the @Sendable callback can mutate without
        // triggering Swift 6 "captured var" warnings.
        final class Box: @unchecked Sendable { var seq: [UInt32] = [] }
        let box = Box()
        let lock = NSLock()
        receiver.onReceive = { packet in
            lock.lock()
            box.seq.append(packet.sequence)
            lock.unlock()
            received.fulfill()
        }

        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: receiverPort)!
        )
        let receiverPeer = PeerInfo(name: "test-receiver", transport: .wifi, endpoint: endpoint)
        for i in 0..<expectedCount {
            sender.sendAudio(
                opusPayload: Data([UInt8(i)]),
                nonce: Packet.zeroNonce(),
                to: receiverPeer
            )
        }

        wait(for: [received], timeout: 5)
        XCTAssertEqual(box.seq.count, expectedCount)
        sender.stop()
        receiver.stop()
    }

    /// Two transports on localhost should exchange a packet end-to-end.
    /// This exercises bind, NWConnection send, and NWListener receive together.
    func testLocalhostRoundtrip() throws {
        let sender = UDPTransport()
        let receiver = UDPTransport()
        try sender.start(advertisingAs: "test-sender")
        try receiver.start(advertisingAs: "test-receiver")

        // Wait for both listeners to bind.
        let bound = expectation(description: "listeners bound")
        Task {
            for _ in 0..<50 where sender.localPort == nil || receiver.localPort == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            bound.fulfill()
        }
        wait(for: [bound], timeout: 5)

        guard let receiverPort = receiver.localPort else {
            return XCTFail("Receiver failed to bind a port")
        }

        let received = expectation(description: "packet received")
        let expectedPayload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        receiver.onReceive = { packet in
            XCTAssertEqual(packet.type, .audio)
            XCTAssertEqual(packet.payload, expectedPayload)
            received.fulfill()
        }

        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: receiverPort)!
        )
        let receiverPeer = PeerInfo(name: "test-receiver", transport: .wifi, endpoint: endpoint)
        sender.sendAudio(
            opusPayload: expectedPayload,
            nonce: Packet.zeroNonce(),
            to: receiverPeer
        )

        wait(for: [received], timeout: 5)
        sender.stop()
        receiver.stop()
    }
}
