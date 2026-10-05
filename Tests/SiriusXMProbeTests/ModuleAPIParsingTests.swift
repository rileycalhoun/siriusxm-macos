import Foundation
import Testing

@testable import SiriusXMProbe

/// Envelope parsing for the legacy module API.
///
/// The single rule that matters: only `ModuleListResponse.status == 1` means
/// authenticated. Everything else, including a status this probe has never
/// seen, is carried forward and reported rather than rounded up to success.
@Suite("Module API response parsing")
struct ModuleAPIParsingTests {
    @Test("status 1 is authenticated")
    func statusOneIsAuthenticated() throws {
        let parsed = try ModuleAPIParser.parse(Fixtures.text("module-auth-success.json"))

        #expect(parsed.status == .authenticated)
        #expect(parsed.status.isAuthenticated)
        #expect(parsed.status.displayToken == "1")
        #expect(parsed.primaryCode == .success)
        #expect(!parsed.hasExpired)
        #expect(!parsed.hasCredentialFailure)
    }

    @Test("status 0 is not authenticated")
    func statusZeroIsNotAuthenticated() throws {
        let parsed = try ModuleAPIParser.parse(Fixtures.text("module-auth-unauthenticated.json"))

        #expect(parsed.status == .notAuthenticated)
        #expect(!parsed.status.isAuthenticated)
        #expect(parsed.status.displayToken == "not-1")
        #expect(parsed.hasCredentialFailure)
    }

    @Test("a status outside 0 and 1 is carried, never coerced to authenticated")
    func unexpectedStatusIsCarried() throws {
        let parsed = try ModuleAPIParser.parse(Fixtures.text("module-auth-status-two.json"))

        #expect(parsed.status == .unrecognized(2))
        #expect(!parsed.status.isAuthenticated)
        #expect(parsed.status.displayToken == "unexpected(2)")
    }

    @Test("no non-1 fixture is ever parsed as authenticated")
    func onlyStatusOneAuthenticates() throws {
        let notAuthenticated = [
            "module-auth-unauthenticated.json",
            "module-auth-code-208.json",
            "module-auth-code-999.json",
            "module-auth-status-two.json",
            "module-resume-unauthenticated.json"
        ]

        for name in notAuthenticated {
            let parsed = try ModuleAPIParser.parse(Fixtures.text(name))
            #expect(!parsed.status.isAuthenticated, "\(name) must not parse as authenticated")
        }
    }

    @Test("a non-JSON body is rejected as notJSON")
    func nonJSONIsRejected() throws {
        let body = try Fixtures.text("module-auth-not-json.txt")

        #expect(throws: ModuleAPIParserError.notJSON) {
            _ = try ModuleAPIParser.parse(body)
        }
    }

    @Test("JSON without the envelope is rejected as missingModuleListResponse")
    func missingEnvelopeIsRejected() throws {
        let body = try Fixtures.text("module-auth-missing-envelope.json")

        #expect(throws: ModuleAPIParserError.missingModuleListResponse) {
            _ = try ModuleAPIParser.parse(body)
        }
    }

    @Test("a complete cookie set splits into one field per cookie")
    func completeCookieSetSplits() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-authenticated.txt")

        #expect(cookies.map(\.name) == ["AWSALB", "SXMAUTH", "SXMAKTOKEN", "SXMDATA", "JSESSIONID"])
    }

    @Test("an Expires comma does not split a cookie")
    func expiresCommaIsNotABoundary() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-authenticated.txt")
        let loadBalancer = try #require(cookies.first { $0.name == "AWSALB" })

        // The `Expires=Mon, 12 Oct 2026 ...` attribute must survive intact
        // and, because attributes are dropped, must not reach the value.
        #expect(loadBalancer.value == "syn-alb")
    }

    @Test("a comma inside a cookie value does not split a cookie")
    func valueCommaIsNotABoundary() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-authenticated.txt")
        let akToken = try #require(cookies.first { $0.name == "SXMAKTOKEN" })

        #expect(akToken.value == "w=syn-ak,x=1")
    }

    @Test("attributes after the first semicolon are dropped from the value")
    func attributesAreDropped() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-authenticated.txt")

        #expect(cookies.allSatisfy { !$0.value.contains(";") })
        #expect(cookies.allSatisfy { !$0.value.lowercased().contains("path=") })
    }

    @Test("a malformed cookie set yields names with empty values and no credentials")
    func malformedCookieSetYieldsNothingUsable() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-malformed.txt")

        #expect(cookies.map(\.name) == ["EMPTY", "ALSOEMPTY", "JSESSIONID"])
        #expect(cookies.allSatisfy { $0.value.isEmpty })
        #expect(ModuleAPIParser.extractAKToken(fromCookies: cookies) == nil)
        #expect(ModuleAPIParser.extractGupID(fromCookies: cookies) == nil)
    }

    @Test("a Set-Cookie field with no equals sign is not a cookie")
    func noEqualsIsNotACookie() throws {
        #expect(try Fixtures.cookieFields("cookie-set-no-equals.txt").isEmpty)
    }

    @Test("an absent Set-Cookie header yields no cookies")
    func absentHeaderYieldsNoCookies() throws {
        #expect(EphemeralHTTPClient.cookieFields(fromHeader: "").isEmpty)
        #expect(ModuleAPIParser.extractAKToken(fromCookies: []) == nil)
        #expect(ModuleAPIParser.extractGupID(fromCookies: []) == nil)
    }

    @Test("cookie presence is summarised by name only")
    func presenceSummaryCarriesNamesOnly() throws {
        let authenticated = try Fixtures.cookieFields("cookie-set-authenticated.txt")
        let summary = ModuleAPIParser.describeCookiePresence(authenticated)

        #expect(summary == "SXMAUTH,SXMAKTOKEN,SXMDATA,JSESSIONID,AWSALB")
        #expect(!summary.contains("syn-alb"))
        #expect(!summary.contains("syn-ak"))
        #expect(!summary.contains("syn-js"))

        #expect(ModuleAPIParser.describeCookiePresence([]) == "none")
    }
}

