import XCTest
@testable import WalkieTalkie

final class PairingServiceTests: XCTestCase {

    /// Use a unique service name per test so the shared Keychain can't collide
    /// with a previous run's leftover key on the simulator.
    private func makeService() -> PairingService {
        let store = KeyStore(service: "com.klick.walkietalkie.tests.\(UUID().uuidString)")
        return PairingService(store: store)
    }

    func testGenerateAndParseRoundtrip() throws {
        let a = makeService()
        let (key, payload) = try a.generateAndStoreKey()
        XCTAssertEqual(key.count, CryptoService.keyBytes)

        let b = makeService()
        let parsed = try b.acceptScannedPayload(payload)
        XCTAssertEqual(parsed, key, "scanned key must match generated key")
    }

    func testMalformedPayloadThrows() {
        let svc = makeService()
        XCTAssertThrowsError(try svc.acceptScannedPayload("not-a-walkie-code"))
    }

    func testWrongSchemeThrows() {
        let svc = makeService()
        let bad = "otherapp:v1:YWJjZA"
        XCTAssertThrowsError(try svc.acceptScannedPayload(bad))
    }

    func testWrongVersionThrows() throws {
        let svc = makeService()
        let key = Data(repeating: 0x42, count: CryptoService.keyBytes)
        let payload = "\(PairingService.scheme):v99:\(key.base64URLEncoded())"
        XCTAssertThrowsError(try svc.acceptScannedPayload(payload)) { err in
            guard case PairingService.PairingError.unsupportedVersion = err else {
                return XCTFail("Expected unsupportedVersion, got \(err)")
            }
        }
    }

    func testBadKeyLengthThrows() {
        let svc = makeService()
        let tooShort = Data([0xff, 0xee, 0xdd])
        let payload = "\(PairingService.scheme):v1:\(tooShort.base64URLEncoded())"
        XCTAssertThrowsError(try svc.acceptScannedPayload(payload))
    }

    func testBase64URLRoundtrip() {
        // `+` and `/` should become `-` and `_`; padding `=` stripped and restored.
        let raw = Data([0xFA, 0xFB, 0xFC, 0xFD, 0xFE])
        let encoded = raw.base64URLEncoded()
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, raw)
    }
}
