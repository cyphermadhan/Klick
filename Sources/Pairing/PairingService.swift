import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Handles the out-of-band key exchange: one side generates a shared key and
/// renders it as a QR code; the other side scans it.
///
/// The QR payload is a versioned blob so we can evolve the format later
/// without conflating it with anything else the camera might see:
///
///     `walkie:v1:<base64url(32-byte key)>`
final class PairingService: Sendable {
    enum PairingError: Error, Sendable {
        case invalidQRCode
        case unsupportedVersion
        case invalidKeyLength
        case qrGenerationFailed
    }

    static let scheme = "walkie"
    static let version = "v1"
    static let channelScheme = "klick"
    static let channelVersion = "ch"

    private let crypto = CryptoService()
    private let store: KeyStore

    init(store: KeyStore = KeyStore()) {
        self.store = store
    }

    // MARK: - Device A (displaying)

    /// Generate a new shared key, persist it, and return a string ready for QR encoding.
    func generateAndStoreKey() throws -> (key: Data, qrPayload: String) {
        let key = crypto.generateKey()
        try store.save(key)
        return (key, qrPayload(for: key))
    }

    /// If a key is already stored, return it. Otherwise mint a fresh one and
    /// store it. Prefer this over `generateAndStoreKey` during normal opens
    /// of the pair screen — re-opening to display the code should NOT
    /// overwrite the already-paired key.
    func loadOrGenerateKey() throws -> (key: Data, qrPayload: String) {
        if let existing = try store.load(), existing.count == CryptoService.keyBytes {
            return (existing, qrPayload(for: existing))
        }
        return try generateAndStoreKey()
    }

    /// Short, human-verifiable fingerprint for a key. Same format used on
    /// both sides so two devices can eyeball that the hex groups match.
    /// Returns "A1B2.C3D4" style (64 bits of the key).
    static func fingerprint(of key: Data) -> String {
        let prefix = key.prefix(8)
        let hex = prefix.map { String(format: "%02X", $0) }.joined()
        let groups = stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: min(4, hex.count - i))
            return String(hex[start..<end])
        }
        return groups.joined(separator: ".")
    }

    /// Fingerprint for the currently stored key, or nil if unpaired.
    func currentKeyFingerprint() -> String? {
        guard let key = try? store.load(), key.count == CryptoService.keyBytes else {
            return nil
        }
        return Self.fingerprint(of: key)
    }

    func qrPayload(for key: Data) -> String {
        "\(Self.scheme):\(Self.version):\(key.base64URLEncoded())"
    }

    /// Render a QR code as a UIImage. Returns a crisp image at the requested
    /// side length (points). The QR code is generated at its native tiny size
    /// then scaled up nearest-neighbor so the pixels stay hard-edged.
    func renderQR(payload: String, side: CGFloat = 240) throws -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { throw PairingError.qrGenerationFailed }
        let scale = side / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            throw PairingError.qrGenerationFailed
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - Device B (scanning)

    /// Parse a QR payload and persist the extracted key. Throws on any format
    /// or length mismatch — callers should surface that to the user.
    @discardableResult
    func acceptScannedPayload(_ payload: String) throws -> Data {
        let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == Self.scheme else {
            throw PairingError.invalidQRCode
        }
        guard parts[1] == Self.version else { throw PairingError.unsupportedVersion }
        guard let key = Data(base64URLEncoded: String(parts[2])),
              key.count == CryptoService.keyBytes else {
            throw PairingError.invalidKeyLength
        }
        try store.save(key)
        return key
    }

    /// Returns the currently paired key if any.
    func currentKey() throws -> Data? {
        try store.load()
    }

    func unpair() throws {
        try store.clear()
    }

    // MARK: - Channel QR (v2)

    /// Generate a QR payload for inviting someone to a channel.
    /// Format: `klick:ch:<base64url(channelId)>:<base64url(channelKey)>:<base64url(channelName)>`
    func channelQRPayload(channelId: String, channelKey: Data, channelName: String) -> String {
        let parts = [
            Self.channelScheme,
            Self.channelVersion,
            Data(channelId.utf8).base64URLEncoded(),
            channelKey.base64URLEncoded(),
            Data(channelName.utf8).base64URLEncoded()
        ]
        return parts.joined(separator: ":")
    }

    /// Parse a channel QR payload. Returns nil if it's not a channel invite QR.
    func parseChannelQR(_ payload: String) -> (channelId: String, channelKey: Data, channelName: String)? {
        let parts = payload.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0] == Self.channelScheme,
              parts[1] == Self.channelVersion else { return nil }
        guard let idData = Data(base64URLEncoded: String(parts[2])),
              let channelId = String(data: idData, encoding: .utf8) else { return nil }
        guard let channelKey = Data(base64URLEncoded: String(parts[3])),
              channelKey.count == CryptoService.keyBytes else { return nil }
        guard let nameData = Data(base64URLEncoded: String(parts[4])),
              let channelName = String(data: nameData, encoding: .utf8) else { return nil }
        return (channelId, channelKey, channelName)
    }

    /// Check if a scanned payload is a v1 legacy pairing or a channel invite.
    @MainActor
    func acceptScannedPayloadUnified(_ payload: String, channelStore: ChannelStore) throws -> AcceptResult {
        if let channelInfo = parseChannelQR(payload) {
            let member = ChannelMember(name: DeviceName.current, addedAt: .now)
            let channel = channelStore.create(
                name: channelInfo.channelName,
                key: channelInfo.channelKey,
                members: [member]
            )
            return .channelJoined(channel)
        }
        let key = try acceptScannedPayload(payload)
        return .legacyPaired(key)
    }

    enum AcceptResult {
        case legacyPaired(Data)
        case channelJoined(Channel)
    }
}

// MARK: - Base64 URL-safe helpers

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded: String) {
        var s = base64URLEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad.
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }
}
