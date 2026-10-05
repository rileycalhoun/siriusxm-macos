import Foundation
import Testing

@testable import SiriusXMProbe

/// `SXMDATA` is a percent-encoded JSON object with `gupId` at the top level.
/// Some responses encode it more than once, so decoding is retried.
@Suite("gupId extraction")
struct GupIDExtractionTests {
    static let expected = "syn-gupid"

    @Test("a URL-encoded SXMDATA yields the gupId")
    func urlEncodedYieldsGupID() throws {
        #expect(ModuleAPIParser.parseGupID(try Fixtures.singleLine("sxmdata-urlencoded.txt")) == Self.expected)
    }

    @Test("an already-plain SXMDATA yields the same gupId")
    func plainYieldsSameGupID() throws {
        #expect(ModuleAPIParser.parseGupID(try Fixtures.singleLine("sxmdata-plain.txt")) == Self.expected)
    }

    @Test("double encoding is unwrapped")
    func doubleEncodedYieldsGupID() throws {
        let once = try Fixtures.singleLine("sxmdata-urlencoded.txt")
        let twice = try #require(once.removingPercentEncoding)

        #expect(ModuleAPIParser.parseGupID(twice) == Self.expected)
    }

    @Test("an SXMDATA without a gupId yields nothing")
    func missingGupIDYieldsNothing() throws {
        #expect(ModuleAPIParser.parseGupID(try Fixtures.singleLine("sxmdata-no-gupid.txt")) == nil)
    }

    @Test("a non-JSON SXMDATA yields nothing rather than throwing")
    func garbageYieldsNothing() {
        #expect(ModuleAPIParser.parseGupID("not json at all") == nil)
        #expect(ModuleAPIParser.parseGupID("") == nil)
        #expect(ModuleAPIParser.parseGupID("%7B%22gupId%22%3A%22%22%7D") == nil)
    }

    @Test("extraction reads the gupId out of a full cookie set")
    func extractionFromCookieSet() throws {
        let cookies = try Fixtures.cookieFields("cookie-set-authenticated.txt")

        #expect(ModuleAPIParser.extractGupID(fromCookies: cookies) == Self.expected)

        let withoutData = cookies.filter { $0.name != ModuleAPIParser.dataCookieName }
        #expect(ModuleAPIParser.extractGupID(fromCookies: withoutData) == nil)
    }

    @Test("percent decoding is idempotent")
    func percentDecodingIsIdempotent() throws {
        let raw = try Fixtures.singleLine("sxmdata-urlencoded.txt")
        let once = ModuleAPIParser.percentDecoded(raw)

        #expect(once == #"{"gupId":"syn-gupid"}"#)
        #expect(ModuleAPIParser.percentDecoded(once) == once)
    }
}