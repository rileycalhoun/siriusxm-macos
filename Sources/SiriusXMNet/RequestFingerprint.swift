import Foundation

/// A stable, secret-free identifier for "the same request".
///
/// Two requests that differ only in their token share a fingerprint. That is
/// the whole point: the fingerprint is a correlation key used to count
/// attempts and to tell a duplicate from a new request, so folding the token
/// in would make it useless and folding it out makes it safe to log.
///
/// Not a security primitive. It is a 64-bit FNV-1a digest, which is
/// implemented here in four lines rather than pulled from CryptoKit so that
/// the same value comes out on every platform this package builds for.
public struct RequestFingerprint: Sendable, Hashable, CustomStringConvertible {
    public let value: String

    private init(value: String) {
        self.value = value
    }

    public static func of(_ request: HTTPRequestSpec) -> RequestFingerprint {
        // The URL is rendered through `RedactingURL`, so the query string is
        // already gone before it reaches the digest. The body is digested
        // rather than embedded, because a request body can be an audio
        // manifest request echo or an error page.
        var canonical = "\(request.method.rawValue)|\(request.url)|"
        if let body = request.body, !body.isEmpty {
            canonical += "\(body.count):\(digest(body))"
        }
        return RequestFingerprint(value: hex(digest(Data(canonical.utf8))))
    }

    public var description: String { "fp:\(value)" }

    private static func digest(_ bytes: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = "0123456789abcdef"
        var characters = [Character](repeating: "0", count: 16)
        for offset in 0..<16 {
            let shift = UInt64((15 - offset) * 4)
            let nibble = Int((value >> shift) & 0xF)
            characters[offset] = Array(digits)[nibble]
        }
        return String(characters)
    }
}
