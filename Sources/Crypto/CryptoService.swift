import Foundation
import Sodium

/// Thin wrapper around libsodium's `crypto_secretbox` (XSalsa20 + Poly1305).
///
/// `seal` generates a random 24-byte nonce per packet and returns both the
/// ciphertext and the nonce. Callers place the nonce in the packet header
/// (see `PacketProtocol`) and the ciphertext in the payload.
///
/// `open` authenticates and decrypts. A wrong key, wrong nonce, or any
/// payload tampering returns `nil` — callers should drop those packets.
/// Sodium itself is thread-safe (libsodium's primitives are), but the Swift
/// wrapper class isn't annotated Sendable. We vouch for it at this boundary.
final class CryptoService: @unchecked Sendable {
    enum CryptoError: Error, Sendable {
        case sealFailed
        case openFailed
        case invalidKeyLength
        case invalidNonceLength
    }

    static let keyBytes = 32
    static let nonceBytes = 24

    private let sodium: Sodium

    init() {
        self.sodium = Sodium()
    }

    /// Generate a fresh random 32-byte symmetric key.
    /// Used by the "display" side of pairing (device A) to mint the shared key.
    func generateKey() -> Data {
        let key = sodium.secretBox.key()
        return Data(key)
    }

    /// Generate a fresh random 24-byte nonce. Nonce must be unique per
    /// (key, message) pair — we never reuse across packets under the same key.
    func generateNonce() -> Data {
        Data(sodium.randomBytes.buf(length: Self.nonceBytes) ?? [])
    }

    /// Encrypt `plaintext` with `key`. Returns `(ciphertext, nonce)`.
    /// The nonce is freshly generated; store it alongside the ciphertext.
    func seal(_ plaintext: Data, key: Data) throws -> (ciphertext: Data, nonce: Data) {
        guard key.count == Self.keyBytes else { throw CryptoError.invalidKeyLength }
        // swift-sodium has two overloads for seal — one returns nonce-prepended
        // bytes, the other returns a (cipher, nonce) tuple. Disambiguate by
        // pinning the return type.
        let result: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce)? =
            sodium.secretBox.seal(message: Array(plaintext), secretKey: Array(key))
        guard let result else { throw CryptoError.sealFailed }
        return (Data(result.authenticatedCipherText), Data(result.nonce))
    }

    /// Decrypt `ciphertext` using `key` and `nonce`. Returns `nil` on any
    /// failure (wrong key, wrong nonce, tampering). Never throws for crypto
    /// failures — we want callers to silently drop bad packets without log
    /// spam from normal-operation drops (packet loss, peer restarts).
    func open(ciphertext: Data, key: Data, nonce: Data) -> Data? {
        guard key.count == Self.keyBytes, nonce.count == Self.nonceBytes else { return nil }
        guard let plain = sodium.secretBox.open(
            authenticatedCipherText: Array(ciphertext),
            secretKey: Array(key),
            nonce: Array(nonce)
        ) else { return nil }
        return Data(plain)
    }
}
