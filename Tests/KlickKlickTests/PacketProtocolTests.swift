import XCTest
@testable import KlickKlick

final class PacketProtocolTests: XCTestCase {

    func testRoundtrip() throws {
        let nonce = Data((0..<24).map { UInt8($0) })
        let payload = Data((0..<123).map { UInt8($0 & 0xff) })
        let original = Packet(
            type: .audio,
            sequence: 42,
            timestampMs: 1_700_000_000_000,
            nonce: nonce,
            payload: payload
        )
        let encoded = original.encode()
        XCTAssertEqual(encoded.count, Packet.headerSize + payload.count)

        let decoded = try Packet.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testPingHasEmptyPayload() throws {
        let pkt = Packet(
            type: .ping,
            sequence: 1,
            timestampMs: 0,
            nonce: Packet.zeroNonce(),
            payload: Data()
        )
        let encoded = pkt.encode()
        XCTAssertEqual(encoded.count, Packet.headerSize)
        let decoded = try Packet.decode(encoded)
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(decoded.payload.count, 0)
    }

    func testShortBufferThrows() {
        XCTAssertThrowsError(try Packet.decode(Data([0x01, 0x01])))
    }

    func testUnknownVersionThrows() {
        var bytes = Data(repeating: 0, count: Packet.headerSize)
        bytes[0] = 0xFF // bad version
        bytes[1] = 0x01
        XCTAssertThrowsError(try Packet.decode(bytes)) { error in
            guard case Packet.DecodeError.unknownVersion(0xFF) = error else {
                return XCTFail("Expected unknownVersion, got \(error)")
            }
        }
    }

    func testUnknownTypeThrows() {
        var bytes = Data(repeating: 0, count: Packet.headerSize)
        bytes[0] = Packet.version
        bytes[1] = 0xAA // bad type
        XCTAssertThrowsError(try Packet.decode(bytes))
    }

    func testLengthMismatchThrows() {
        var bytes = Data(repeating: 0, count: Packet.headerSize)
        bytes[0] = Packet.version
        bytes[1] = 0x01
        // Declare payload length = 100 but provide no payload bytes.
        bytes[38] = 0
        bytes[39] = 100
        XCTAssertThrowsError(try Packet.decode(bytes))
    }
}
