import XCTest
@testable import KlickKlick

final class CryptoServiceTests: XCTestCase {

    func testSealOpenRoundtrip() throws {
        let crypto = CryptoService()
        let key = crypto.generateKey()
        let plaintext = Data("hello walkie".utf8)
        let (ciphertext, nonce) = try crypto.seal(plaintext, key: key)
        XCTAssertNotEqual(ciphertext, plaintext, "ciphertext must differ from plaintext")
        XCTAssertEqual(nonce.count, CryptoService.nonceBytes)
        let decrypted = crypto.open(ciphertext: ciphertext, key: key, nonce: nonce)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testWrongKeyReturnsNil() throws {
        let crypto = CryptoService()
        let key1 = crypto.generateKey()
        let key2 = crypto.generateKey()
        let (ciphertext, nonce) = try crypto.seal(Data("top secret".utf8), key: key1)
        XCTAssertNil(crypto.open(ciphertext: ciphertext, key: key2, nonce: nonce))
    }

    func testTamperedCiphertextReturnsNil() throws {
        let crypto = CryptoService()
        let key = crypto.generateKey()
        var (ciphertext, nonce) = try crypto.seal(Data("intact".utf8), key: key)
        ciphertext[0] ^= 0x01 // flip a single bit
        XCTAssertNil(crypto.open(ciphertext: ciphertext, key: key, nonce: nonce))
    }

    func testWrongNonceReturnsNil() throws {
        let crypto = CryptoService()
        let key = crypto.generateKey()
        let (ciphertext, _) = try crypto.seal(Data("abc".utf8), key: key)
        let wrongNonce = crypto.generateNonce()
        XCTAssertNil(crypto.open(ciphertext: ciphertext, key: key, nonce: wrongNonce))
    }

    func testNoncesAreUnique() {
        let crypto = CryptoService()
        let n1 = crypto.generateNonce()
        let n2 = crypto.generateNonce()
        XCTAssertNotEqual(n1, n2)
        XCTAssertEqual(n1.count, CryptoService.nonceBytes)
    }

    func testInvalidKeyLengthThrows() {
        let crypto = CryptoService()
        XCTAssertThrowsError(try crypto.seal(Data(), key: Data([0x01, 0x02])))
    }
}
