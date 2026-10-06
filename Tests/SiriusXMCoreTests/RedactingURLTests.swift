import Foundation
import Testing

@testable import SiriusXMCore

/// The leak paths a token-bearing URL has, one test per path.
///
/// `RedactingURL` only earns its existence if every way of getting a string
/// out of a `URL` is closed. The list below is that list: the two description
/// protocols, interpolation, being stored in a struct, being put in a
/// collection, being boxed as `Optional` or `Any`, and being the member of a
/// type whose own `debugDescription` is synthesised.
///
/// Reflection is deliberately *not* on that list, and it took a second
/// conformance (`CustomReflectable`) to close, because `dump()` and `Mirror`
/// ignore the description protocols entirely and walk stored properties
/// instead. The two tests under "Reflection" below cover that path; the rest
/// of the suite covers the description protocols.
///
/// Each test uses a sentinel that appears nowhere else in the file, so a leak
/// is attributed to the path under test rather than to some other coincidence.
@Suite("Redacting URL")
struct RedactingURLTests {
    static let secret = "SECRETTOKENVALUE"
    static let userInfoSecret = "SECRETPASSWORD"
    static let fragmentSecret = "SECRETFRAGMENT"

    static var tokenBearing: RedactingURL {
        RedactingURL(string: "https://live.example.invalid/stream/track.m3u8?token=\(secret)&gupId=\(secret)")!
    }

    // MARK: - The two description protocols

    @Test("description hides the query")
    func descriptionHidesQuery() {
        let rendered = String(describing: Self.tokenBearing)

        #expect(!rendered.contains(Self.secret))
        #expect(rendered == "https://live.example.invalid/stream/track.m3u8?<redacted>")
    }

    @Test("debugDescription hides the query")
    func debugDescriptionHidesQuery() {
        let rendered = String(reflecting: Self.tokenBearing)

        #expect(!rendered.contains(Self.secret))
        #expect(rendered.contains("?<redacted>"))
    }

    // MARK: - Reflection
    //
    // `dump()` and `Mirror` do not consult `description` or
    // `debugDescription`. They walk stored properties, so before
    // `CustomReflectable` existed they printed the private `url` in full.

    @Test("dump() renders no token")
    func dumpRendersNoToken() {
        // `dump()` writes to `stderr` by default, which a test cannot read
        // back, so it is redirected into a `TextOutputStream` sink instead.
        var sink = ""
        dump(Self.tokenBearing, to: &sink)

        #expect(!sink.isEmpty, "expected dump() to produce output at all")
        #expect(!sink.contains(Self.secret))
        #expect(!sink.contains("?token="))
    }

    @Test("Mirror exposes no child carrying the token")
    func mirrorChildrenCarryNoToken() {
        let mirror = Mirror(reflecting: Self.tokenBearing)
        let rendered = mirror.children
            .map { "\($0.label ?? "-"): \($0.value)" }
            .joined(separator: "\n")

        #expect(!rendered.contains(Self.secret))
    }

    @Test("Mirror exposes no URL at all, not even a partial one")
    func mirrorExposesNoURL() {
        let mirror = Mirror(reflecting: Self.tokenBearing)

        for child in mirror.children {
            #expect(!(child.value is URL))
        }
    }

    // MARK: - Interpolation

    @Test("interpolation uses the redacted form")
    func interpolationIsRedacted() {
        let rendered = "GET \(Self.tokenBearing) failed"

        #expect(!rendered.contains(Self.secret))
        #expect(rendered == "GET https://live.example.invalid/stream/track.m3u8?<redacted> failed")
    }

    @Test("interpolation inside a literal with more than one segment is redacted")
    func interpolationInCompoundLiteralIsRedacted() {
        let rendered = "\(Self.tokenBearing) then \(Self.tokenBearing)"

        #expect(!rendered.contains(Self.secret))
    }

    // MARK: - Nesting

    @Test("a struct that holds one renders redacted")
    func nestingInAStructIsRedacted() {
        struct Handoff: CustomStringConvertible, CustomDebugStringConvertible {
            let target: RedactingURL
            var description: String { "Handoff(\(target))" }
            var debugDescription: String { "Handoff(\(target))" }
        }

        let handoff = Handoff(target: Self.tokenBearing)
        for rendered in [String(describing: handoff), String(reflecting: handoff)] {
            #expect(!rendered.contains(Self.secret))
        }
    }

    @Test("a struct with no custom description still renders redacted")
    func nestingInAPlainStructIsRedacted() {
        struct Playlist {
            let name: String
            let entry: RedactingURL
        }

        let playlist = Playlist(name: "late night", entry: Self.tokenBearing)
        for rendered in [String(describing: playlist), String(reflecting: playlist)] {
            #expect(!rendered.contains(Self.secret))
        }
    }

    // MARK: - Collection membership

    @Test("an array containing one renders redacted")
    func membershipInAnArrayIsRedacted() {
        let array = [Self.tokenBearing]

        for rendered in [String(describing: array), String(reflecting: array)] {
            #expect(!rendered.contains(Self.secret))
        }
    }

    @Test("a set containing one renders redacted")
    func membershipInASetIsRedacted() {
        let set: Set<RedactingURL> = [Self.tokenBearing]

        for rendered in [String(describing: set), String(reflecting: set)] {
            #expect(!rendered.contains(Self.secret))
        }
    }

    @Test("a dictionary keyed and valued by one renders redacted")
    func membershipInADictionaryIsRedacted() {
        let dictionary = [Self.tokenBearing: Self.tokenBearing]

        for rendered in [String(describing: dictionary), String(reflecting: dictionary)] {
            #expect(!rendered.contains(Self.secret))
        }
    }

    @Test("membership is decided by value, not by rendering")
    func membershipIsValueBased() {
        let set: Set<RedactingURL> = [Self.tokenBearing]

        // Equality is by URL value, so a lookup cannot be used to smuggle a
        // token out, and cannot be fooled by two renderings of one URL.
        #expect(set.contains(Self.tokenBearing))
        #expect(!set.contains(RedactingURL(string: "https://live.example.invalid/other")!))
    }

    // MARK: - Erased types

    @Test("an optional wrapping one renders redacted")
    func erasedByOptionalIsRedacted() {
        let optional: RedactingURL? = Self.tokenBearing
        let rendered = String(reflecting: optional)

        #expect(!rendered.contains(Self.secret))
    }

    @Test("an Any wrapping one renders redacted")
    func erasedByAnyIsRedacted() {
        let erased: Any = Self.tokenBearing
        let rendered = String(reflecting: erased)

        #expect(!rendered.contains(Self.secret))
    }

    // MARK: - Every sensitive component

    @Test("a fragment is redacted")
    func fragmentIsRedacted() {
        let url = RedactingURL(string: "https://example.invalid/a#\(Self.fragmentSecret)")!

        #expect(!String(describing: url).contains(Self.fragmentSecret))
        #expect(String(describing: url) == "https://example.invalid/a#<redacted>")
    }

    @Test("embedded credentials are redacted")
    func userInfoIsRedacted() {
        let url = RedactingURL(string: "https://subscriber:\(Self.userInfoSecret)@example.invalid/a")!

        #expect(!String(describing: url).contains(Self.userInfoSecret))
        #expect(!String(reflecting: url).contains(Self.userInfoSecret))
    }

    @Test("a port survives redaction because it is not a secret")
    func portSurvivesRedaction() {
        let url = RedactingURL(string: "https://example.invalid:8443/a?token=\(Self.secret)")!

        #expect(String(describing: url) == "https://example.invalid:8443/a?<redacted>")
    }

    @Test("a token-free URL renders in full, because hiding it helps nobody")
    func tokenFreeURLRendersInFull() {
        let url = RedactingURL(string: "https://images.example.invalid/art/channel-17.jpg")!

        #expect(!url.carriesSensitiveComponents)
        #expect(String(describing: url) == "https://images.example.invalid/art/channel-17.jpg")
    }

    @Test("the sensitive-component flag is true for query, fragment, and userinfo")
    func sensitiveComponentFlagIsExact() {
        #expect(RedactingURL(string: "https://example.invalid/a?b=1")!.carriesSensitiveComponents)
        #expect(RedactingURL(string: "https://example.invalid/a#f")!.carriesSensitiveComponents)
        #expect(RedactingURL(string: "https://u@example.invalid/a")!.carriesSensitiveComponents)
        #expect(!RedactingURL(string: "https://example.invalid/a")!.carriesSensitiveComponents)
    }

    // MARK: - The escape hatch

    @Test("resolvedURL is the real URL, so the app can actually send it")
    func resolvedURLIsTheRealURL() {
        let url = Self.tokenBearing

        #expect(url.resolvedURL.absoluteString.contains(Self.secret))
        // …and it is not reachable from the printable form.
        #expect(!String(describing: url).contains(Self.secret))
    }

    @Test("read accessors report the parts that are safe to show")
    func safeAccessors() {
        let url = Self.tokenBearing

        #expect(url.scheme == "https")
        #expect(url.host == "live.example.invalid")
        #expect(url.path == "/stream/track.m3u8")
    }

    @Test("a string that is not a URL never renders as text")
    func unparseableStringYieldsNothing() {
        #expect(RedactingURL(string: "") == nil)

        // How much whitespace Foundation tolerates differs between platforms
        // and this app does not depend on the difference: either the
        // initialiser declines the string, or the renderer refuses it. Neither
        // outcome may echo the input back out.
        for candidate in ["   ", "just some words", "%%%"] {
            guard let url = RedactingURL(string: candidate) else { continue }
            #expect(String(describing: url) == RedactingURL.unrenderable)
            #expect(!String(describing: url).contains(candidate))
        }
    }

    @Test("a scheme-less string renders as unrenderable rather than as text")
    func schemeLessStringDoesNotRenderRawText() {
        let url = RedactingURL(string: "just-a-path?token=\(Self.secret)")!

        // URL(string:) accepts this, so the renderer has to refuse rather than
        // echo an input it could not take apart.
        #expect(String(describing: url) == RedactingURL.unrenderable)
        #expect(!String(describing: url).contains(Self.secret))
    }
}
