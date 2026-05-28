import Foundation

struct ChannelInvite: Identifiable, Sendable {
    let id: UUID
    let channelId: String
    let channelName: String
    let channelKey: Data
    let senderName: String
    let receivedAt: Date
}

// MARK: - Wire codec

enum ChannelInviteCodec {
    enum CodecError: Error {
        case payloadTooShort
        case nameTooLong
        case invalidUTF8
    }

    /// Encode invite payload (to be encrypted before sending).
    /// Format: [channelId: 36 bytes][nameLen: 1][name: N bytes][key: 32 bytes]
    static func encodeInvite(channelId: String, channelName: String, channelKey: Data) throws -> Data {
        let idBytes = Data(channelId.utf8)
        guard idBytes.count == 36 else { throw CodecError.payloadTooShort }
        let nameBytes = Data(channelName.utf8)
        guard nameBytes.count <= 32 else { throw CodecError.nameTooLong }
        guard channelKey.count == 32 else { throw CodecError.payloadTooShort }

        var out = Data(capacity: 36 + 1 + nameBytes.count + 32)
        out.append(idBytes)
        out.append(UInt8(nameBytes.count))
        out.append(nameBytes)
        out.append(channelKey)
        return out
    }

    /// Decode invite payload (after decryption).
    static func decodeInvite(_ data: Data) throws -> (channelId: String, channelName: String, channelKey: Data) {
        guard data.count >= 36 + 1 + 32 else { throw CodecError.payloadTooShort }

        let idData = data[data.startIndex..<(data.startIndex + 36)]
        guard let channelId = String(data: idData, encoding: .utf8) else { throw CodecError.invalidUTF8 }

        let nameLen = Int(data[data.startIndex + 36])
        guard data.count >= 36 + 1 + nameLen + 32 else { throw CodecError.payloadTooShort }

        let nameStart = data.startIndex + 37
        let nameData = data[nameStart..<(nameStart + nameLen)]
        guard let channelName = String(data: nameData, encoding: .utf8) else { throw CodecError.invalidUTF8 }

        let keyStart = nameStart + nameLen
        let channelKey = data[keyStart..<(keyStart + 32)]

        return (channelId, channelName, Data(channelKey))
    }

    /// Encode invite response payload.
    /// Format: [channelId: 36 bytes][accepted: 1 byte]
    static func encodeResponse(channelId: String, accepted: Bool) throws -> Data {
        let idBytes = Data(channelId.utf8)
        guard idBytes.count == 36 else { throw CodecError.payloadTooShort }
        var out = Data(capacity: 37)
        out.append(idBytes)
        out.append(accepted ? 0x01 : 0x00)
        return out
    }

    /// Decode invite response payload.
    static func decodeResponse(_ data: Data) throws -> (channelId: String, accepted: Bool) {
        guard data.count >= 37 else { throw CodecError.payloadTooShort }
        let idData = data[data.startIndex..<(data.startIndex + 36)]
        guard let channelId = String(data: idData, encoding: .utf8) else { throw CodecError.invalidUTF8 }
        let accepted = data[data.startIndex + 36] == 0x01
        return (channelId, accepted)
    }
}
