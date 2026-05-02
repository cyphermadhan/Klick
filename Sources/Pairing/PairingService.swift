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
