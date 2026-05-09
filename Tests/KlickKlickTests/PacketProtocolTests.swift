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

    func testMorseTextRoundtrip() throws {
        // `morseText` carries an (already-encrypted) UTF-8 payload. The
        // wire format is unchanged from audio — this just confirms the
        // new type byte roundtrips through decode without a special case.
        let payload = Data("HELLO OM 73".utf8)
        let original = Packet(
            type: .morseText,
            sequence: 7,
            timestampMs: 1_700_000_001_234,
            nonce: Packet.zeroNonce(),
            payload: payload
        )
        let encoded = original.encode()
        let decoded = try Packet.decode(encoded)
        XCTAssertEqual(decoded.type, .morseText)
        XCTAssertEqual(decoded, original)
    }

    func testChatTextRoundtrip() throws {
        // Chat uses the same wire shape as audio/morse; the distinction
        // is only the type byte so the receiver can route to the Chat view.
        let payload = Data("hey, meet at the main stage".utf8)
        let original = Packet(
            type: .chatText,
            sequence: 42,
            timestampMs: 1_700_000_002_345,
            nonce: Packet.zeroNonce(),
            payload: payload
        )
        let encoded = original.encode()
        let decoded = try Packet.decode(encoded)
        XCTAssertEqual(decoded.type, .chatText)
        XCTAssertEqual(decoded, original)
    }

    func testAckCarriesSequenceBytes() throws {
        // Ack payload is the BE-encoded seq of the packet being acked so
        // senders can mark that message delivered.
        let ackedSeq: UInt32 = 0xDEAD_BEEF
        var payload = Data()
        payload.append(UInt8((ackedSeq >> 24) & 0xFF))
        payload.append(UInt8((ackedSeq >> 16) & 0xFF))
        payload.append(UInt8((ackedSeq >> 8) & 0xFF))
        payload.append(UInt8(ackedSeq & 0xFF))

        let original = Packet(
            type: .ack,
            sequence: 99,
            timestampMs: 0,
            nonce: Packet.zeroNonce(),
            payload: payload
        )
        let encoded = original.encode()
        let decoded = try Packet.decode(encoded)
        XCTAssertEqual(decoded.type, .ack)
        XCTAssertEqual(decoded.payload.count, 4)
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
