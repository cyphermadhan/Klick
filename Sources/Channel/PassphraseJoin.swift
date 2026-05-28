import Foundation
import CryptoKit

/// Derives a channel key and room ID from a passphrase.
/// Uses HKDF (SHA-256) with a fixed salt so all devices with the same
/// passphrase arrive at the same 32-byte key + the same relay room.
///
/// This enables "open frequency" join — share a word, anyone who knows
/// it can derive the key and connect. No QR or invite needed.
enum PassphraseJoin {
    /// Fixed salt for HKDF derivation. Changing this invalidates all
    /// existing passphrase-derived channels.
    private static let salt = "klick-passphrase-v1".data(using: .utf8)!

    /// Derive a 32-byte symmetric key from a passphrase.
    static func deriveKey(from passphrase: String) -> Data {
        let inputKey = SymmetricKey(data: Data(passphrase.utf8))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: "channel-key".data(using: .utf8)!,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// Derive a deterministic channel ID from a passphrase.
    /// Different from the key so the relay room ID isn't reversible to the key.
    static func deriveChannelId(from passphrase: String) -> String {
        let input = Data((passphrase + ":channel-id").utf8)
        let hash = SHA256.hash(data: input)
        return hash.map { String(format: "%02x", $0) }.joined().prefix(36).description
    }

    /// Derive a display-friendly channel name from the passphrase.
    /// Takes the first word, uppercased, max 16 chars.
    static func deriveChannelName(from passphrase: String) -> String {
        let word = passphrase.split(separator: " ").first.map(String.init) ?? passphrase
        return String(word.uppercased().prefix(16))
    }
}
