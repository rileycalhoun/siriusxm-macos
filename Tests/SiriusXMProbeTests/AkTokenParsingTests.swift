import Foundation
import Testing

@testable import SiriusXMProbe

/// `SXMAKTOKEN` arrives as `…=<token>,…`: an opaque wrapper on the left of
/// the first `=`, and everything after the first `,` is noise. The wrapper is
/// not stable across responses, so the token is taken positionally rather
/// than by key.
@Suite("SXMAKTOKEN parsing")
struct AkTokenParsingTests {
    @Test("the wrapped form yields the token between the equals and the comma")
    func wrappedFormYieldsToken() throws {
        #expect(ModuleAPIParser.parseAKToken(try Fixtures.singleLine("aktoken-wrapped.txt")) == "syn-ak")
    }

    @Test("a value with no equals is not a token")
    func noEqualsIsNotAToken() throws {
        #expect(ModuleAPIParser.parseAKToken(try Fixtures.singleLine("aktoken-no-equals.txt")) == nil)
    }

    @Test("an empty token between the equals and the comma is not a token")
    func emptyTokenIsNotAToken() throws {
        #expect(ModuleAPIParser.parseAKToken(try Fixtures.singleLine("aktoken-empty-token.txt")) == nil)
        #expect(ModuleAPIParser.parseAKToken("w=") == nil)
        #expect(ModuleAPIParser.parseAKToken("w=,x=1") == nil)
    }

    @Test("only the first equals separates the wrapper from the token")
    func firstEqualsWins() {
        // A base64 blob contains `=` padding, so the split must not be greedy
        // on the left and must not rejoin on the right.
        #expect(ModuleAPIParser.parseAKToken("a=b=c,d") == "b=c")
    }

    @Test("a bare token with no wrapper and no comma is still accepted")
    func bareTokenIsAccepted() {
        #expect(ModuleAPIParser.parseAKToken("w=syn-ak") == "syn-ak")
    }

    @Test("surrounding whitespace is trimmed off the token")
    func whitespaceIsTrimmed() {
        #expect(ModuleAPIParser.parseAKToken("w= syn-ak ,x=1") == "syn-ak")
    }

    @Test("extraction finds the token only when the cookie is present")
    func extractionRequiresTheCookie() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-authenticated.txt")

        #expect(ModuleAPIParser.extractAKToken(fromCookies: cookies) == "syn-ak")

        let withoutAK = cookies.filter { $0.name != ModuleAPIParser.akTokenCookieName }
        #expect(ModuleAPIParser.extractAKToken(fromCookies: withoutAK) == nil)
    }
}