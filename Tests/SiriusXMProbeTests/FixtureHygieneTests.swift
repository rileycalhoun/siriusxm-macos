import Foundation
import Testing

@testable import SiriusXMProbe

/// Fixture hygiene is a build-breaking rule, not a review convention.
///
/// Every byte these fixtures hold is checked in, so a stray paste of a live
/// token, a real cookie value, a real account id, or a real hostname would
/// land in permanent git history. This suite reads every fixture file and
/// fails on any of those shapes.
///
/// The final test in the suite feeds the patterns known-bad samples, so a
/// future edit that quietly weakens a pattern fails loudly instead of
/// silently passing everything.
@Suite("Fixture hygiene")
struct FixtureHygieneTests {
    /// A base64url/base64/JWT-shaped run. Real access tokens, AK tokens and
    /// `SXMAUTH` values are all longer than this.
    static let tokenPattern = "[A-Za-z0-9_+/=-]{24,}"

    static let uuidPattern = "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

    /// Production hostnames and their distinctive fragments.
    static let hostnamePattern = "(?i)siriusxm|edge-gateway|akamai|\\.streaming\\."

    static let urlWithQueryPattern = "[A-Za-z][A-Za-z0-9+.-]*://[^\\s\"']*\\?"

    @Test("no fixture contains a token-shaped string")
    func noTokenShapedStrings() throws {
        try Self.assertNoMatch(Self.tokenPattern, label: "token-shaped string")
    }

    @Test("no fixture contains a UUID")
    func noUUIDs() throws {
        try Self.assertNoMatch(Self.uuidPattern, label: "UUID")
    }

    @Test("no fixture names a production host")
    func noProductionHostnames() throws {
        try Self.assertNoMatch(Self.hostnamePattern, label: "production hostname")
    }

    @Test("no fixture contains a URL with a query string")
    func noURLWithQueryString() throws {
        try Self.assertNoMatch(Self.urlWithQueryPattern, label: "URL with a query string")
    }

    @Test("the hygiene patterns still match known-bad samples")
    func patternsAreEffective() throws {
        let badToken = "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123+/ab"
        let badUUID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let badHost = "api.edge-gateway.example.com"
        let badQuery = "https://example.invalid/a?token=1"

        try Self.expectMatch(Self.tokenPattern, in: badToken, label: "token sample")
        try Self.expectMatch(Self.uuidPattern, in: badUUID, label: "UUID sample")
        try Self.expectMatch(Self.hostnamePattern, in: badHost, label: "hostname sample")
        try Self.expectMatch(Self.urlWithQueryPattern, in: badQuery, label: "query-string sample")
    }

    @Test("the fixtures this suite parses all exist and are readable")
    func expectedFixturesArePresent() throws {
        let names = Set(try Fixtures.allFileURLs().map(\.lastPathComponent))
        let expected: Set<String> = [
            "aktoken-empty-token.txt",
            "aktoken-no-equals.txt",
            "aktoken-wrapped.txt",
            "cookie-set-authenticated.txt",
            "cookie-set-malformed.txt",
            "cookie-set-no-equals.txt",
            "module-auth-code-208.json",
            "module-auth-code-999.json",
            "module-auth-missing-envelope.json",
            "module-auth-not-json.txt",
            "module-auth-status-two.json",
            "module-auth-success.json",
            "module-auth-unauthenticated.json",
            "module-resume-unauthenticated.json",
            "sxmdata-no-gupid.txt",
            "sxmdata-plain.txt",
            "sxmdata-urlencoded.txt"
        ]

        #expect(names == expected)
    }

    // MARK: - Helpers

    private static func scan(_ pattern: String) throws -> [(file: String, snippet: String)] {
        let expression = try NSRegularExpression(pattern: pattern)
        var hits: [(file: String, snippet: String)] = []

        for url in try Fixtures.allFileURLs() {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = expression.matches(in: text, range: range)

            for match in matches {
                let snippet = (text as NSString).substring(with: match.range)
                hits.append((url.lastPathComponent, snippet))
            }
        }

        return hits
    }

    private static func assertNoMatch(
        _ pattern: String,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for hit in try scan(pattern) {
            Issue.record(
                "fixture \(hit.file) contains a \(label): \(hit.snippet)",
                sourceLocation: sourceLocation
            )
        }
    }

    private static func expectMatch(
        _ pattern: String,
        in sample: String,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        let matched = expression.firstMatch(in: sample, range: range) != nil

        #expect(matched, "hygiene pattern no longer detects a \(label)", sourceLocation: sourceLocation)
    }
}