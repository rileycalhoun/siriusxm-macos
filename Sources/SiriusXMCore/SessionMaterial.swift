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
///
/// A password has no field here and never will. A session is the only thing
/// allowed to cross the credential boundary, and a session is not a password.
public struct SessionMaterial: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bumped whenever the meaning of the stored fields changes.
    public static let currentSchemaVersion = 1

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

    public init(
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

    public var resolvedToken: String? { token }
    public var resolvedGupID: String? { gupID }
    public var resolvedCookieNames: [String] { cookieNames }
    public var resolvedIssuedAt: Date? { issuedAt }
    public var resolvedExpiresAt: Date? { expiresAt }
    public var resolvedSchemaVersion: Int { schemaVersion }

    /// A session is usable when it carries at least one credential the
    /// matching protocol generation can present.
    public var isUsable: Bool {
        let hasToken = !(token ?? "").isEmpty
        let hasGupID = !(gupID ?? "").isEmpty
        return hasToken || hasGupID
    }

    /// Unknown expiry is never treated as expired; the protocol calls it.
    ///
    /// The `at:` form exists so that a caller holding a clock of its own — a
    /// test, or a view model replaying a recorded run — never has to reach for
    /// `Date()` and get a different answer twice.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public var isExpired: Bool { isExpired(at: Date()) }

    public func isUsableAndFresh(at now: Date) -> Bool {
        isUsable && !isExpired(at: now)
    }

    public var description: String {
        "SessionMaterial(token: <redacted>, gupID: <redacted>, cookieNames: <redacted>, issuedAt: <redacted>, expiresAt: <redacted>, schemaVersion: <redacted>)"
    }

    public var debugDescription: String { description }
}
