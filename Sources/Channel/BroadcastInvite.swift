import Foundation

/// Codec for broadcast invite packets that spread to all nearby devices.
/// These are UNENCRYPTED (so unpaired devices can read them) and contain
/// just the channel name + optional passphrase. Receiving devices derive
/// the key locally from the passphrase via HKDF.
enum BroadcastInviteCodec {
    enum CodecError: Error {
        case payloadTooShort
        case invalidUTF8
    }

    /// Encode a broadcast invite payload.
    /// Format: [TTL: 1][channelNameLen: 1][channelName: N][passphraseLen: 1][passphrase: M]
    static func encode(channelName: String, passphrase: String, ttl: UInt8 = 3) -> Data {
        let nameBytes = Data(channelName.utf8)
        let phraseBytes = Data(passphrase.utf8)
        var out = Data(capacity: 1 + 1 + nameBytes.count + 1 + phraseBytes.count)
        out.append(ttl)
        out.append(UInt8(min(nameBytes.count, 32)))
        out.append(nameBytes.prefix(32))
        out.append(UInt8(min(phraseBytes.count, 64)))
        out.append(phraseBytes.prefix(64))
        return out
    }

    /// Decode a broadcast invite payload.
    static func decode(_ data: Data) throws -> (ttl: UInt8, channelName: String, passphrase: String) {
        guard data.count >= 3 else { throw CodecError.payloadTooShort }
        let ttl = data[data.startIndex]
        let nameLen = Int(data[data.startIndex + 1])
        guard data.count >= 2 + nameLen + 1 else { throw CodecError.payloadTooShort }
        let nameData = data[(data.startIndex + 2)..<(data.startIndex + 2 + nameLen)]
        guard let channelName = String(data: nameData, encoding: .utf8) else { throw CodecError.invalidUTF8 }
        let phraseLen = Int(data[data.startIndex + 2 + nameLen])
        let phraseStart = data.startIndex + 3 + nameLen
        guard data.count >= 3 + nameLen + phraseLen else { throw CodecError.payloadTooShort }
        let phraseData = data[phraseStart..<(phraseStart + phraseLen)]
        let passphrase = String(data: phraseData, encoding: .utf8) ?? ""
        return (ttl, channelName, passphrase)
    }

    /// Re-encode with decremented TTL for forwarding.
    static func forward(_ data: Data) -> Data? {
        guard data.count >= 1 else { return nil }
        var forwarded = data
        let ttl = forwarded[forwarded.startIndex]
        guard ttl > 0 else { return nil }
        forwarded[forwarded.startIndex] = ttl - 1
        return forwarded
    }
}
