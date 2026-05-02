import Foundation

/// Wire format for every UDP packet exchanged between peers.
///
/// ```
/// [ version: 1 ]
/// [ type:    1 ]   0x01 audio, 0x02 ping, 0x03 pong
/// [ seq:     4 ]   big-endian monotonic counter
/// [ ts:      8 ]   big-endian sender ms-since-boot (for jitter/latency)
/// [ nonce:  24 ]   libsodium secretbox nonce (zeroed until M3 wires crypto)
/// [ len:     2 ]   big-endian payload length
/// [ payload: N ]   encrypted Opus frame (or empty for ping/pong)
/// ```
///
/// Header is exactly 40 bytes. Kept deliberately small and endian-explicit
/// so the wire format is stable across M2 (no crypto) and M3 (real crypto).
enum PacketType: UInt8, Sendable {
    case audio = 0x01
    case ping  = 0x02
    case pong  = 0x03
}

struct Packet: Sendable, Equatable {
    static let version: UInt8 = 1
    static let headerSize = 40
    static let nonceSize = 24

    var type: PacketType
    var sequence: UInt32
    var timestampMs: UInt64
    var nonce: Data   // exactly 24 bytes
    var payload: Data

    init(type: PacketType, sequence: UInt32, timestampMs: UInt64, nonce: Data, payload: Data) {
        precondition(nonce.count == Packet.nonceSize, "nonce must be \(Packet.nonceSize) bytes")
        self.type = type
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.nonce = nonce
        self.payload = payload
    }

    /// Encode the packet to its wire-format bytes.
    func encode() -> Data {
        var out = Data(capacity: Packet.headerSize + payload.count)
        out.append(Packet.version)
        out.append(type.rawValue)
        out.appendBE(sequence)
        out.appendBE(timestampMs)
        out.append(nonce)
        out.appendBE(UInt16(payload.count))
        out.append(payload)
        return out
    }

    enum DecodeError: Error, Equatable {
        case tooShort
        case unknownVersion(UInt8)
        case unknownType(UInt8)
        case lengthMismatch(expected: Int, actual: Int)
    }

    /// Parse a packet from raw bytes received on the wire.
    static func decode(_ data: Data) throws -> Packet {
        guard data.count >= headerSize else { throw DecodeError.tooShort }
        let version = data[data.startIndex]
        guard version == Packet.version else { throw DecodeError.unknownVersion(version) }
        let typeByte = data[data.startIndex + 1]
        guard let type = PacketType(rawValue: typeByte) else { throw DecodeError.unknownType(typeByte) }

        let sequence = data.readBE(at: 2, as: UInt32.self)
        let timestamp = data.readBE(at: 6, as: UInt64.self)
        let nonce = data.subdata(in: (data.startIndex + 14)..<(data.startIndex + 14 + nonceSize))
        let length = Int(data.readBE(at: 38, as: UInt16.self))

        let payloadStart = data.startIndex + headerSize
        let payloadEnd = payloadStart + length
        guard payloadEnd <= data.endIndex else {
            throw DecodeError.lengthMismatch(expected: length, actual: data.count - headerSize)
        }
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        return Packet(type: type, sequence: sequence, timestampMs: timestamp, nonce: nonce, payload: payload)
    }

    static func zeroNonce() -> Data { Data(repeating: 0, count: nonceSize) }

    static func currentTimestampMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - Big-endian helpers

extension Data {
    fileprivate mutating func appendBE(_ value: UInt16) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }
    fileprivate mutating func appendBE(_ value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }
    fileprivate mutating func appendBE(_ value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { self.append(contentsOf: $0) }
    }

    fileprivate func readBE<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
        let start = self.startIndex + offset
        let end = start + MemoryLayout<T>.size
        var value: T = 0
        self.subdata(in: start..<end).withUnsafeBytes { raw in
            value = raw.load(as: T.self)
        }
        return T(bigEndian: value)
    }
}
