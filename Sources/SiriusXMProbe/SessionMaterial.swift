import Foundation

/// Everything the app must hold to keep a live session, and nothing it is
/// allowed to print.
///
/// Redaction contract: every stored field renders as `<redacted>` in both
/// `description` and `debugDescription`, so neither `String(describing:)`
/// nor `String(reflecting:)` can leak a token, cookie value, device id, or
/// timestamp. Callers that legitimately need a value read the `resolved…`
/// accessors and pass the value straight into a request builder.
///
/// This type deliberately has no `Codable` conformance. Encoding a session is
/// how credentials end up on disk.
struct SessionMaterial: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bumped whenever the meaning of the stored fields changes.
    static let currentSchemaVersion = 1

    /// Token used by whichever protocol generation produced this session:
    /// the edge-gateway access token, or the legacy module-API AK token.
    private let token: String?

    /// Legacy media identifier carried in `SXMDATA`. Unused by the edge
    /// gateway, retained so a legacy session stays self-describing.
    private let gupID: String?

    /// Names only, never values. Enough to classify a session's provenance.
    private let cookieNames: [String]

    private let issuedAt: Date?
    private let expiresAt: Date?
    private let schemaVersion: Int

    init(
        token: String? = nil,
        gupID: String? = nil,
        cookieNames: [String] = [],
        issuedAt: Date? = nil,
        expiresAt: Date? = nil,
        schemaVersion: Int = SessionMaterial.currentSchemaVersion
    ) {
        self.token = token
        self.gupID = gupID
        self.cookieNames = cookieNames
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.schemaVersion = schemaVersion
    }

    var resolvedToken: String? { token }
    var resolvedGupID: String? { gupID }
    var resolvedCookieNames: [String] { cookieNames }
    var resolvedIssuedAt: Date? { issuedAt }
    var resolvedExpiresAt: Date? { expiresAt }
    var resolvedSchemaVersion: Int { schemaVersion }

    /// A session is usable when it carries at least one credential the
    /// matching protocol generation can present.
    var isUsable: Bool {
        let hasToken = !(token ?? "").isEmpty
        let hasGupID = !(gupID ?? "").isEmpty
        return hasToken || hasGupID
    }

    /// Unknown expiry is never treated as expired; the protocol calls it.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var isUsableAndFresh: Bool { isUsable && !isExpired }

    var description: String {
        "SessionMaterial(token: <redacted>, gupID: <redacted>, cookieNames: <redacted>, issuedAt: <redacted>, expiresAt: <redacted>, schemaVersion: <redacted>)"
    }

    var debugDescription: String { description }
}