import Foundation
import Testing

@testable import SiriusXMCore

/// Nothing that holds a credential may render one.
///
/// This is the Phase 0.5 redaction suite, re-homed onto the domain module.
/// The probe keeps its own copy for the report types it owns; this copy guards
/// the type the app actually holds.
@Suite("Session material redaction")
struct SessionMaterialRedactionTests {
    // Long enough to be token-shaped on purpose, so the description
    // implementations are forced to deal with it.
    static let sentinelToken = "AAAedge-access-token-valueBBB"
    static let sentinelGupID = "CCCgup-id-valueDDD"
    static let sentinelCookieName = "EEEcookie-name-valueFFF"
    static let sentinelEpoch = "1700000000"

    static var populated: SessionMaterial {
        SessionMaterial(
            token: sentinelToken,
            gupID: sentinelGupID,
            cookieNames: [sentinelCookieName],
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("a populated session leaks nothing to String(describing:)")
    func descriptionIsRedacted() {
        let rendered = String(describing: Self.populated)

        Self.assertNoSentinels(rendered)
        #expect(rendered.contains("<redacted>"))
        #expect(rendered == "SessionMaterial(token: <redacted>, gupID: <redacted>, cookieNames: <redacted>, issuedAt: <redacted>, expiresAt: <redacted>, schemaVersion: <redacted>)")
    }

    @Test("a populated session leaks nothing to String(reflecting:)")
    func reflectionIsRedacted() {
        Self.assertNoSentinels(String(reflecting: Self.populated))
    }

    @Test("interpolation and collection rendering stay redacted")
    func interpolatedAndNestedRenderingIsRedacted() {
        let material = Self.populated
        let nested = ["session": material]
        let rendered = [
            String(describing: material),
            String(reflecting: material),
            String(describing: nested),
            String(reflecting: nested),
            String(describing: [material, material])
        ].joined(separator: "\n")

        Self.assertNoSentinels(rendered)
    }

    @Test("even the schema version is not printed")
    func schemaVersionIsRedacted() {
        let material = Self.populated

        #expect(!String(describing: material).contains(String(SessionMaterial.currentSchemaVersion)))
        // The accessors still work; redaction is a rendering rule, not an
        // erasure rule.
        #expect(material.resolvedSchemaVersion == SessionMaterial.currentSchemaVersion)
        #expect(material.resolvedToken == Self.sentinelToken)
        #expect(material.isUsable)
    }

    @Test("expiry is decided against a supplied clock, not against Date()")
    func expiryTakesAClock() {
        let session = SessionMaterial(
            token: "t",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        #expect(!session.isExpired(at: Date(timeIntervalSince1970: 999)))
        #expect(session.isExpired(at: Date(timeIntervalSince1970: 1_000)))
        #expect(session.isExpired(at: Date(timeIntervalSince1970: 1_001)))
        #expect(session.isUsableAndFresh(at: Date(timeIntervalSince1970: 999)))
        #expect(!session.isUsableAndFresh(at: Date(timeIntervalSince1970: 1_001)))
    }

    @Test("an unknown expiry is never read as expired")
    func unknownExpiryIsNotExpired() {
        let session = SessionMaterial(token: "t")

        #expect(!session.isExpired)
        #expect(session.isUsableAndFresh(at: Date(timeIntervalSince1970: 9_999_999_999)))
    }

    @Test("an empty session carries no credential at all")
    func emptySessionIsNotUsable() {
        #expect(!SessionMaterial().isUsable)
        #expect(!SessionMaterial(token: "", gupID: "").isUsable)
    }

    @Test("values are handed out only through explicit resolved accessors")
    func resolvedAccessors() {
        let session = SessionMaterial(token: "t", gupID: "g", cookieNames: ["n"])

        #expect(session.resolvedToken == "t")
        #expect(session.resolvedGupID == "g")
        #expect(session.resolvedCookieNames == ["n"])
        #expect(session.resolvedIssuedAt == nil)
        #expect(session.resolvedExpiresAt == nil)
        #expect(session.resolvedSchemaVersion == SessionMaterial.currentSchemaVersion)
    }

    private static func assertNoSentinels(
        _ rendered: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for sentinel in [sentinelToken, sentinelGupID, sentinelCookieName, sentinelEpoch] {
            #expect(
                !rendered.contains(sentinel),
                "leaked \(sentinel.prefix(4))…",
                sourceLocation: sourceLocation
            )
        }
    }
}
