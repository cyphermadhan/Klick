import Foundation
import os

/// Persists whether this device participates as a mesh relay node.
@MainActor
enum MeshRelayStore {
    private static let key = "klick.meshRelay"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Flood-based mesh relay with TTL and deduplication.
///
/// When a phone receives a relay-wrapped packet, it checks:
/// 1. TTL > 0 (not expired)
/// 2. Not already seen (dedup cache)
/// 3. Not originated by self
///
/// If all pass, decrement TTL and rebroadcast to all other connected peers.
/// The inner packet is also tried locally for decryption (maybe it's for us).
final class MeshRelay: @unchecked Sendable {
    struct PacketID: Hashable {
        let origin: String
        let seq: UInt32
    }

    struct Envelope: Sendable {
        let ttl: UInt8
        let origin: String
        let innerData: Data
    }

    private let maxTTL: UInt8 = 3
    private let cacheLimit = 500
    private var seenPackets: Set<PacketID> = []
    private var seenOrder: [PacketID] = []
    private let selfName: String
    private let log = Logger(subsystem: "world.madhans.klick", category: "MeshRelay")

    init(selfName: String) {
        self.selfName = selfName
    }

    /// Check if we should forward this envelope.
    func shouldForward(_ envelope: Envelope) -> Bool {
        guard envelope.ttl > 0 else { return false }
        guard envelope.origin != selfName else { return false }
        let id = PacketID(origin: envelope.origin, seq: extractSeq(from: envelope.innerData))
        guard !seenPackets.contains(id) else { return false }
        recordSeen(id)
        return true
    }

    /// Mark a packet as originated by self (prevents re-forwarding our own relayed packets).
    func markSent(origin: String, seq: UInt32) {
        let id = PacketID(origin: origin, seq: seq)
        recordSeen(id)
    }

    /// Wrap an inner packet into a relay envelope.
    /// Format: [TTL: 1][originNameLen: 1][originName: N][innerPacket: rest]
    func wrap(innerPacketData: Data, origin: String, ttl: UInt8) -> Data {
        let originBytes = Data(origin.utf8)
        var out = Data(capacity: 1 + 1 + originBytes.count + innerPacketData.count)
        out.append(ttl)
        out.append(UInt8(originBytes.count))
        out.append(originBytes)
        out.append(innerPacketData)
        return out
    }

    /// Unwrap a relay envelope from raw payload bytes.
    func unwrap(_ data: Data) -> Envelope? {
        guard data.count >= 3 else { return nil }  // TTL + nameLen + at least 1 byte
        let ttl = data[data.startIndex]
        let nameLen = Int(data[data.startIndex + 1])
        let nameStart = data.startIndex + 2
        guard data.count >= 2 + nameLen + Packet.headerSize else { return nil }
        let nameData = data[nameStart..<(nameStart + nameLen)]
        guard let origin = String(data: nameData, encoding: .utf8) else { return nil }
        let innerData = Data(data[(nameStart + nameLen)...])
        return Envelope(ttl: ttl, origin: origin, innerData: innerData)
    }

    /// Decrement TTL and re-wrap for forwarding.
    func rewrap(_ envelope: Envelope) -> Data? {
        guard envelope.ttl > 0 else { return nil }
        return wrap(innerPacketData: envelope.innerData, origin: envelope.origin, ttl: envelope.ttl - 1)
    }

    // MARK: - Private

    private func extractSeq(from innerData: Data) -> UInt32 {
        // Sequence is at offset 2 in the Packet header (after version + type).
        guard innerData.count >= 6 else { return 0 }
        let start = innerData.startIndex + 2
        var value: UInt32 = 0
        innerData.subdata(in: start..<(start + 4)).withUnsafeBytes { raw in
            value = raw.load(as: UInt32.self)
        }
        return UInt32(bigEndian: value)
    }

    private func recordSeen(_ id: PacketID) {
        seenPackets.insert(id)
        seenOrder.append(id)
        if seenOrder.count > cacheLimit {
            let evict = seenOrder.removeFirst()
            seenPackets.remove(evict)
        }
    }
}
