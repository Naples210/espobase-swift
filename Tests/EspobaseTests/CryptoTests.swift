import XCTest

@testable import Espobase

final class CryptoTests: XCTestCase {
    func testSHA256StandardVectors() {
        func hex(_ s: String) -> String { SHA256Hash.hex(SHA256Hash.hash(Array(s.utf8))) }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Every padding length around the block boundary.
        XCTAssertEqual(hex(String(repeating: "a", count: 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(hex(String(repeating: "a", count: 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        XCTAssertEqual(hex(String(repeating: "a", count: 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    func testPKCEChallengeIsTheS256OfTheVerifier() {
        // RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            Base64URL.encode(SHA256Hash.hash(Array(verifier.utf8))), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pkce = PKCE.make()
        XCTAssertEqual(pkce.verifier.count, 43)
        XCTAssertNotEqual(PKCE.make().verifier, pkce.verifier)
        XCTAssertEqual(pkce.challenge, Base64URL.encode(SHA256Hash.hash(Array(pkce.verifier.utf8))))
    }

    func testAppleNonceHashesTheRawValueAsLowercaseHex() {
        let nonce = AppleNonce(raw: "abc")
        XCTAssertEqual(nonce.hashed, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let random = AppleNonce()
        XCTAssertGreaterThanOrEqual(random.raw.count, 32)
        XCTAssertEqual(random.hashed.count, 64)
        XCTAssertNotEqual(AppleNonce().raw, random.raw)
    }
}
