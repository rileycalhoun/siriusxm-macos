import Foundation
import Testing

@testable import SiriusXMProbe

/// Nothing that holds a credential may render one.
///
/// Every type in this suite that stores a secret implements
/// `CustomStringConvertible` and `CustomDebugStringConvertible` and is
/// required to emit `<redacted>` in place of every field. The assertions use
/// distinctive sentinel values so that any leak, however small, is caught.
@Suite("Secret redaction")
struct RedactionTests {
    // Long enough to be token-shaped on purpose, so the redactor and the
    // description implementations are both forced to deal with it.
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

    @Test("a populated SessionMaterial leaks nothing to String(describing:)")
    func sessionMaterialDescriptionIsRedacted() {
        let material = Self.populated
        let rendered = String(describing: material)

        Self.assertNoSentinels(rendered)
        #expect(rendered.contains("<redacted>"))
        #expect(rendered == "SessionMaterial(token: <redacted>, gupID: <redacted>, cookieNames: <redacted>, issuedAt: <redacted>, expiresAt: <redacted>, schemaVersion: <redacted>)")
    }

    @Test("a populated SessionMaterial leaks nothing to String(reflecting:)")
    func sessionMaterialReflectionIsRedacted() {
        let rendered = String(reflecting: Self.populated)

        Self.assertNoSentinels(rendered)
        #expect(rendered.contains("<redacted>"))
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
        // The accessors still work; redaction is a rendering rule, not
        // an erasure rule.
        #expect(material.resolvedSchemaVersion == SessionMaterial.currentSchemaVersion)
        #expect(material.resolvedToken == Self.sentinelToken)
        #expect(material.isUsable)
        #expect(!material.isExpired)
    }

    @Test("SessionMaterial hands values out only through explicit resolved accessors")
    func sessionMaterialHasExplicitAccessors() {
        let material = SessionMaterial(token: "t", gupID: "g", cookieNames: ["n"])

        #expect(material.resolvedToken == "t")
        #expect(material.resolvedGupID == "g")
        #expect(material.resolvedCookieNames == ["n"])
        #expect(material.resolvedIssuedAt == nil)
        #expect(material.resolvedExpiresAt == nil)
        #expect(material.resolvedSchemaVersion == SessionMaterial.currentSchemaVersion)
    }

    @Test("AccountCredential never renders either half")
    func accountCredentialIsRedacted() {
        let credential = AccountCredential(username: "AAAuserBBB", password: "CCCpasswordDDD")

        for rendered in [String(describing: credential), String(reflecting: credential)] {
            #expect(!rendered.contains("AAAuserBBB"))
            #expect(!rendered.contains("CCCpasswordDDD"))
            #expect(rendered.contains("<redacted>"))
        }
    }

    @Test("a cookie field renders its name and redacts its value")
    func cookieFieldIsRedacted() {
        let cookie = HTTPCookieField(name: "SXMAUTH", value: "EEEcookie-valueFFF")

        for rendered in [String(describing: cookie), String(reflecting: cookie)] {
            #expect(!rendered.contains("EEEcookie-valueFFF"))
            #expect(rendered == "SXMAUTH=<redacted>")
        }
    }

    @Test("an HTTP result renders shape, never body")
    func httpResultIsRedacted() {
        let result = HTTPResult(
            statusCode: 200,
            contentType: "application/json",
            body: #"{"accessToken":"AAAedge-access-tokenBBB"}"#,
            cookies: [HTTPCookieField(name: "SXMAUTH", value: "EEEcookie-valueFFF")],
            transportFailure: nil
        )

        for rendered in [String(describing: result), String(reflecting: result)] {
            #expect(!rendered.contains("AAAedge-access-tokenBBB"))
            #expect(!rendered.contains("EEEcookie-valueFFF"))
            #expect(rendered.contains("body: json"))
            #expect(rendered.contains("cookies: 1"))
        }
    }

    @Test("a transport failure renders a stable slug")
    func transportFailureIsRedacted() {
        let rendered = TransportFailure(URLError(.timedOut)).description

        #expect(rendered == "timed-out")
    }

    // MARK: - Report rendering

    @Test("a report row is exactly five columns")
    func reportRowHasFiveColumns() {
        let row = ProbeReport(
            path: "module-auth-programmatic",
            result: .rejected(statusCode: 401, detail: "messageCode=101"),
            notes: "body=json"
        ).line

        let columns = row.split(separator: "|", omittingEmptySubsequences: false)
        #expect(columns.count == 5)
        #expect(columns[0] == "module-auth-programmatic ")
        #expect(columns[1] == " rejected ")
        #expect(columns[2] == " 401 ")
        #expect(columns[3] == " false ")
        #expect(columns[4] == " body=json; messageCode=101")
    }

    @Test("a report row redacts a secret that reached the notes")
    func reportRowRedactsNotes() {
        let row = ProbeReport(
            path: "module-auth-programmatic",
            result: .acquiredSession,
            notes: "token=\(Self.sentinelToken)"
        ).line

        #expect(!row.contains(Self.sentinelToken))
        #expect(row.contains("<redacted>"))
        #expect(row.split(separator: "|", omittingEmptySubsequences: false).count == 5)
    }

    @Test("a report row strips query strings")
    func reportRowStripsQueryStrings() {
        let row = ProbeReport(
            path: "module-auth-programmatic",
            result: .documented(detail: "seen at https://example.invalid/p?token=abcdef"),
            notes: ""
        ).line

        #expect(!row.contains("token=abcdef"))
        #expect(row.contains("?<redacted>"))
    }

    @Test("only an acquired result sets the acquired column")
    func acquiredColumnIsExact() {
        let results: [ProbeResult] = [
            .observed(statusCode: 401),
            .acquiredSession,
            .rejected(statusCode: 200, detail: "no"),
            .blocked(detail: "no"),
            .documented(detail: "no"),
            .skippedNoCredential(detail: "no"),
            .transportFailure(detail: "no")
        ]

        #expect(results.filter(\.acquired).count == 1)
        #expect(ProbeResult.acquiredSession.statusColumn == "-")
        #expect(ProbeResult.observed(statusCode: 401).statusColumn == "401")
    }

    // MARK: - Redactor

    @Test("the redactor flattens a row-breaking pipe and newline")
    func redactorFlattensLayout() {
        let sanitized = Redactor.sanitize("a|b\nc")

        #expect(sanitized == "a/b c")
        #expect(!sanitized.contains("|"))
        #expect(!sanitized.contains("\n"))
    }

    @Test("the redactor strips query strings")
    func redactorStripsQueryStrings() {
        let sanitized = Redactor.sanitize("https://example.invalid/a/b?token=abcdef&x=1")

        #expect(sanitized == "https://example.invalid/a/b?<redacted>")
        #expect(!sanitized.contains("abcdef"))
    }

    @Test("the redactor collapses a token-shaped run")
    func redactorCollapsesLongRuns() {
        let sanitized = Redactor.sanitize("value \(Self.sentinelToken) tail")

        #expect(!sanitized.contains(Self.sentinelToken))
        #expect(sanitized == "value <redacted> tail")
    }

    @Test("the redactor leaves ordinary prose alone")
    func redactorLeavesProseAlone() {
        let prose = "moduleStatus=not-1; messageCode=101; cookies=0"

        #expect(Redactor.sanitize(prose) == prose)
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