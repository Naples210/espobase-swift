import Foundation

/// SHA-256 in plain Swift: no dependencies, same result on Apple platforms and Linux. Used for the PKCE challenge of
/// a social sign-in and for Sign in with Apple nonces: both hash public, random values, nothing secret.
enum SHA256Hash {
    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitLength = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(padded[j]) << 24 | UInt32(padded[j + 1]) << 16 | UInt32(padded[j + 2]) << 8 | UInt32(padded[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        for word in h { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((word >> UInt32(shift)) & 0xff)) } }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

enum Base64URL {
    static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Random bytes from the system's secure generator.
func secureRandomBytes(_ count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
}

/// RFC 7636 (S256) verifier and challenge for a social sign-in.
struct PKCE {
    let verifier: String
    let challenge: String

    static func make() -> PKCE {
        let verifier = Base64URL.encode(secureRandomBytes(32))
        return PKCE(verifier: verifier, challenge: Base64URL.encode(SHA256Hash.hash(Array(verifier.utf8))))
    }
}

/// Sign in with Apple: the nonce for the sign-in sheet. Give the sheet `hashed` (`request.nonce = nonce.hashed`) and
/// keep `raw` to send to `auth.signInWithIdToken`.
public struct AppleNonce: Sendable, Equatable {
    public let raw: String
    /// SHA-256 of `raw`, lowercase hex (what Apple puts in the identity token).
    public let hashed: String

    public init() {
        let raw = Base64URL.encode(secureRandomBytes(32))
        self.init(raw: raw)
    }

    public init(raw: String) {
        self.raw = raw
        self.hashed = SHA256Hash.hex(SHA256Hash.hash(Array(raw.utf8)))
    }
}
