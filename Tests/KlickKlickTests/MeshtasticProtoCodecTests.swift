import XCTest
@testable import KlickKlick

final class MeshtasticProtoCodecTests: XCTestCase {
    private let codec = MeshtasticProtoCodec()

    // MARK: - Wire primitives

    func testVarintEncodeRoundtripSmall() throws {
        var buf: [UInt8] = []
        ProtobufWire.encodeVarint(1, into: &buf)
        // 1 fits in a single byte; MSB clear.
        XCTAssertEqual(buf, [0x01])
        var r = ProtobufWire.Reader(Data(buf))
        XCTAssertEqual(try r.readVarint(), 1)
    }

    func testVarintEncodeRoundtripMultiByte() throws {
        var buf: [UInt8] = []
        // 300 = 0xAC 0x02 per the canonical protobuf docs example.
        ProtobufWire.encodeVarint(300, into: &buf)
        XCTAssertEqual(buf, [0xAC, 0x02])
        var r = ProtobufWire.Reader(Data(buf))
        XCTAssertEqual(try r.readVarint(), 300)
    }

    func testFixed32EncodeIsLittleEndian() throws {
        var buf: [UInt8] = []
        ProtobufWire.encodeFixed32(0x01020304, into: &buf)
        XCTAssertEqual(buf, [0x04, 0x03, 0x02, 0x01])
        var r = ProtobufWire.Reader(Data(buf))
        XCTAssertEqual(try r.readFixed32(), 0x01020304)
    }

    func testTagBuildsCorrectlyForFieldOneVarint() {
        // (field=1 << 3) | 0 = 0x08
        XCTAssertEqual(ProtobufWire.tag(field: 1, wire: .varint), [0x08])
    }

    func testTagBuildsCorrectlyForFieldTwoLengthDelimited() {
        // (field=2 << 3) | 2 = 0x12
        XCTAssertEqual(ProtobufWire.tag(field: 2, wire: .lengthDelimited), [0x12])
    }

    // MARK: - ToRadio envelope shape

    func testEncodeToRadioHasOuterPacketField() throws {
        let klickBytes = Data("klick-payload".utf8)
        let frame = codec.encodeToRadio(klickBytes)
        // The first tag must be ToRadio.packet (field 1, length-delimited)
        // = 0x0A. This is what Meshtastic firmware expects at offset 0.
        XCTAssertFalse(frame.isEmpty)
        XCTAssertEqual(frame[frame.startIndex], 0x0A)
    }

    func testEncodeToRadioCarriesKlickPayloadIntact() throws {
        // Round-trip via our own decoder to confirm the Klick bytes
        // survive. Relies on field numbers being consistent between
        // encode and decode, so any renumbering will blow up here first.
        let klickBytes = Data("AAAA-BBBB-CCCC".utf8)
        let frame = codec.encodeToRadio(klickBytes)

        // Mirror the structure: ToRadio wraps MeshPacket in field 1,
        // but the decoder looks for FromRadio's field 2. Re-wrap for
        // the round-trip.
        let asFromRadio = rewrapAsFromRadio(toRadioFrame: frame)
        let recovered = codec.decodeFromRadio(asFromRadio)
        XCTAssertEqual(recovered, klickBytes)
    }

    // MARK: - FromRadio decode

    func testDecodeIgnoresFromRadioVariantsOtherThanPacket() throws {
        // FromRadio with only config_complete_id (field 7, varint).
        // No packet field → codec returns nil.
        var bytes: [UInt8] = []
        ProtobufWire.encodeVarintField(7, 42, into: &bytes)
        XCTAssertNil(codec.decodeFromRadio(Data(bytes)))
    }

    func testDecodeIgnoresPacketsOnDifferentPortnum() throws {
        // Build a FromRadio { packet: MeshPacket { decoded: Data { portnum:
        // TEXT_MESSAGE_APP(1), payload: ... } } }. Our codec expects
        // PRIVATE_APP (256), so this should decode to nil.
        let textMessagePortnum: UInt64 = 1
        var dataBytes: [UInt8] = []
        ProtobufWire.encodeVarintField(1, textMessagePortnum, into: &dataBytes)
        ProtobufWire.encodeBytesField(2, Data("hello world".utf8), into: &dataBytes)

        var meshBytes: [UInt8] = []
        ProtobufWire.encodeBytesField(4, Data(dataBytes), into: &meshBytes)

        var fromRadio: [UInt8] = []
        ProtobufWire.encodeBytesField(2, Data(meshBytes), into: &fromRadio)

        XCTAssertNil(codec.decodeFromRadio(Data(fromRadio)))
    }

    func testDecodeReturnsPayloadForPrivateAppPortnum() throws {
        // Same shape but with PRIVATE_APP(256) — the decoder should
        // extract and return the payload.
        let payload = Data("secret-klick-bytes".utf8)
        var dataBytes: [UInt8] = []
        ProtobufWire.encodeVarintField(1, 256, into: &dataBytes)
        ProtobufWire.encodeBytesField(2, payload, into: &dataBytes)

        var meshBytes: [UInt8] = []
        ProtobufWire.encodeBytesField(4, Data(dataBytes), into: &meshBytes)

        var fromRadio: [UInt8] = []
        ProtobufWire.encodeBytesField(2, Data(meshBytes), into: &fromRadio)

        XCTAssertEqual(codec.decodeFromRadio(Data(fromRadio)), payload)
    }

    func testDecodeGracefullyReturnsNilOnTruncatedInput() {
        // Tag says length-delimited N bytes, but buffer is shorter —
        // should fail the read gracefully and return nil rather than
        // crashing or throwing.
        let bytes: [UInt8] = [0x12, 0xFF, 0x01, 0x00] // length=255 but only 1 byte follows
        XCTAssertNil(codec.decodeFromRadio(Data(bytes)))
    }

    // MARK: - Helpers

    /// Convert a ToRadio frame (packet in field 1) to a FromRadio frame
    /// (packet in field 2) by unwrapping and re-wrapping. Lets us test
    /// the decode path with the same bytes the encoder produced.
    private func rewrapAsFromRadio(toRadioFrame: Data) -> Data {
        // Strip the outer tag+length, then re-wrap with the FromRadio
        // packet tag (field 2).
        var reader = ProtobufWire.Reader(toRadioFrame)
        guard let field = try? reader.nextField(),
              field.field == 1,
              field.wire == .lengthDelimited,
              let meshBytes = try? reader.readLengthDelimited() else {
            return toRadioFrame
        }
        var out: [UInt8] = []
        ProtobufWire.encodeBytesField(2, meshBytes, into: &out)
        return Data(out)
    }
}
