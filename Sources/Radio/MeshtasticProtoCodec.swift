import Foundation
import os

/// Real wire-compatible codec for Klick ↔ Meshtastic firmware.
///
/// Encodes Klick `Packet.encode()` bytes as:
///
/// ```
/// ToRadio {
///   packet: MeshPacket {
///     to: 0xFFFFFFFF (BROADCAST)
///     id: random fixed32
///     want_ack: true
///     hop_limit: 3
///     decoded: Data {
///       portnum: PRIVATE_APP (256)
///       payload: <klick-bytes>
///     }
///   }
/// }
/// ```
///
/// Decodes `FromRadio { packet: MeshPacket { decoded: Data { portnum:
/// PRIVATE_APP, payload: ... } } }` by walking the protobuf structure
/// and returning the inner `payload` bytes when — and only when — the
/// portnum matches `PRIVATE_APP`. Any other inbound FromRadio variant
/// (config, my_info, log_record, rebooted) returns `nil`, as does a
/// packet on a different portnum (other users' text messages on the
/// same channel).
///
/// Why PRIVATE_APP and not TEXT_MESSAGE_APP: Meshtastic's phone apps
/// display incoming TEXT_MESSAGE_APP packets as chat. Our payload is an
/// opaque encrypted blob that would render as garbage. PRIVATE_APP (256)
/// is explicitly documented as "use this for your own app's bytes" and
/// is ignored by the stock Meshtastic UI.
///
/// Field numbers verified against meshtastic/protobufs master as of
/// May 2026 (mesh.proto, portnums.proto). If Meshtastic renumbers a
/// field in a future firmware break, the tests here fail loudly.
final class MeshtasticProtoCodec: MeshtasticCodec, @unchecked Sendable {
    enum CodecError: Error, Equatable {
        case malformedFrame
    }

    nonisolated let codecError: Error.Type = CodecError.self
    private let log = Logger(subsystem: "world.madhans.klick", category: "MeshtasticCodec")

    /// Per Meshtastic convention, the destination that means "any node
    /// on the channel". Used as the default recipient for Klick sends
    /// since we're not addressing specific Meshtastic node numbers —
    /// the paired peer is keyed into our libsodium layer, not their mesh.
    static let broadcastAddress: UInt32 = 0xFFFF_FFFF
    /// Port number for app-private opaque payloads. Chosen so stock
    /// Meshtastic clients don't try to render our encrypted bytes as a
    /// chat message.
    static let privateAppPortNum: UInt64 = 256
    /// Conservative multi-hop limit. 3 is the recommended default in
    /// Meshtastic's own docs — enough to reach across a typical mesh
    /// without hammering the network with retransmits.
    static let defaultHopLimit: UInt64 = 3

    // MARK: - Tag numbers

    // Verified against meshtastic/protobufs/mesh.proto @ master (2026-05).
    // Kept as constants rather than hard-coded in bodies so field-number
    // regressions show up in one place.
    private enum ToRadioField {
        static let packet: UInt32 = 1
    }
    private enum FromRadioField {
        static let packet: UInt32 = 2
    }
    private enum MeshPacketField {
        static let from: UInt32 = 1            // fixed32
        static let to: UInt32 = 2              // fixed32
        static let channel: UInt32 = 3         // uint32
        static let decoded: UInt32 = 4         // Data (embedded)
        static let encrypted: UInt32 = 5       // bytes
        static let id: UInt32 = 6              // fixed32
        static let hopLimit: UInt32 = 9        // uint32
        static let wantAck: UInt32 = 10        // bool
    }
    private enum DataField {
        static let portnum: UInt32 = 1         // PortNum enum (varint)
        static let payload: UInt32 = 2         // bytes
    }

    // MARK: - MeshtasticCodec

    func encodeToRadio(_ klickFrame: Data) -> Data {
        // Inner Data message: portnum + payload.
        var dataBytes: [UInt8] = []
        ProtobufWire.encodeVarintField(DataField.portnum, Self.privateAppPortNum, into: &dataBytes)
        ProtobufWire.encodeBytesField(DataField.payload, klickFrame, into: &dataBytes)

        // MeshPacket: to + id + want_ack + hop_limit + decoded(Data).
        // Use a non-zero random id so the firmware can de-dupe the
        // retransmits our own mesh will do. 0 is reserved for "no ack
        // needed" packets which isn't our case.
        let id = nonZeroRandomId()
        var meshBytes: [UInt8] = []
        ProtobufWire.encodeFixed32Field(MeshPacketField.to, Self.broadcastAddress, into: &meshBytes)
        ProtobufWire.encodeFixed32Field(MeshPacketField.id, id, into: &meshBytes)
        ProtobufWire.encodeVarintField(MeshPacketField.hopLimit, Self.defaultHopLimit, into: &meshBytes)
        ProtobufWire.encodeVarintField(MeshPacketField.wantAck, 1, into: &meshBytes) // bool true
        ProtobufWire.encodeBytesField(MeshPacketField.decoded, Data(dataBytes), into: &meshBytes)

        // ToRadio wrapper.
        var toRadioBytes: [UInt8] = []
        ProtobufWire.encodeBytesField(ToRadioField.packet, Data(meshBytes), into: &toRadioBytes)
        return Data(toRadioBytes)
    }

    func decodeFromRadio(_ protobufFrame: Data) -> Data? {
        do {
            var reader = ProtobufWire.Reader(protobufFrame)
            while let field = try reader.nextField() {
                if field.field == FromRadioField.packet && field.wire == .lengthDelimited {
                    let meshBytes = try reader.readLengthDelimited()
                    return try extractKlickPayload(fromMeshPacket: meshBytes)
                }
                try reader.skip(wire: field.wire)
            }
        } catch {
            log.debug("FromRadio decode failed: \(String(describing: error))")
        }
        return nil
    }

    // MARK: - Private

    /// Walk a MeshPacket blob, find the `decoded: Data` field, check its
    /// portnum, and return the `payload` if it matches ours.
    private func extractKlickPayload(fromMeshPacket meshBytes: Data) throws -> Data? {
        var reader = ProtobufWire.Reader(meshBytes)
        while let field = try reader.nextField() {
            if field.field == MeshPacketField.decoded && field.wire == .lengthDelimited {
                let dataBytes = try reader.readLengthDelimited()
                return try extractKlickPayload(fromDataMessage: dataBytes)
            }
            try reader.skip(wire: field.wire)
        }
        return nil
    }

    /// Inside a `Data` message — check portnum == PRIVATE_APP and pull
    /// out the `payload`.
    private func extractKlickPayload(fromDataMessage dataBytes: Data) throws -> Data? {
        var reader = ProtobufWire.Reader(dataBytes)
        var portnum: UInt64 = 0
        var payload: Data?
        while let field = try reader.nextField() {
            switch (field.field, field.wire) {
            case (DataField.portnum, .varint):
                portnum = try reader.readVarint()
            case (DataField.payload, .lengthDelimited):
                payload = try reader.readLengthDelimited()
            default:
                try reader.skip(wire: field.wire)
            }
        }
        guard portnum == Self.privateAppPortNum else { return nil }
        return payload
    }

    /// Random fixed32 id, never 0 (0 is reserved in the Meshtastic
    /// semantic for "no-ack packets" which we're not).
    private func nonZeroRandomId() -> UInt32 {
        while true {
            let v = UInt32.random(in: 1...UInt32.max)
            if v != 0 { return v }
        }
    }
}
