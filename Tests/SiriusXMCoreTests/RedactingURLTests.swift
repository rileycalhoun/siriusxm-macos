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
/// instead. It is covered under "Reflection" below by four tests: the mirror's
/// children, the absence of any `URL` among them, `dump()` of the value, and
/// `dump()` of a value nested inside something else. The first two of those
/// would pass vacuously against an empty mirror, so each one asserts that it
/// is looking at a non-empty thing first.
///
/// Two of the sections below are about the path rather than the query. "Path
/// embedded credentials" runs the credential through every position a path
/// segment can occupy and then through the same description, reflection and
/// nesting paths the query runs through, because a path credential has to be
/// closed on the same terms. "Ordinary URLs" is the counterweight: it exists
/// to prove the path rule is narrow, and every case in it must render in full.
///
/// Each assertion checks against a sentinel constant defined once at the top of
/// this file, so a leak is attributed to the path under test rather than to
/// some other coincidence.
@Suite("Redacting URL")
struct RedactingURLTests {
    static let secret = "SECRETTOKENVALUE"
    static let userInfoSecret = "SECRETPASSWORD"
    static let fragmentSecret = "SECRETFRAGMENT"

    // Path-borne credentials. Three shapes, because the classification rule
    // has to catch three shapes: a hex digest, a base64 blob with case in it,
    // and an alphanumeric run whose letters never spell a word.
    static let hexPathSecret = "9f3c1b7e2a4d"
    static let base64PathSecret = "Zm9vYmFyYmF6cXV4"
    static let runLessPathSecret = "qm9x8k2zp4nr"

    static var tokenBearing: RedactingURL {
        RedactingURL(string: "https://live.example.invalid/stream/track.m3u8?token=\(secret)&gupId=\(secret)")!
    }

    /// A URL whose only credential is in the path, which is the case that used
    /// to render in full.
    static var pathBearing: RedactingURL {
        RedactingURL(string: "https://live.example.invalid/v1/stream/\(hexPathSecret)/playback.m3u8")!
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

    @Test("dump() renders no path-embedded credential")
    func dumpRendersNoPathSecret() {
        var sink = ""
        dump(Self.pathBearing, to: &sink)

        #expect(!sink.isEmpty, "expected dump() to produce output at all")
        #expect(!sink.contains(Self.hexPathSecret))
        // The reflection path is only actually closed if it renders the
        // redacted form rather than quietly rendering nothing.
        #expect(sink.contains(RedactingURL.redaction))
    }

    @Test("dump() of a value nested in something else renders no path credential")
    func dumpOfNestedValueRendersNoPathSecret() {
        struct Handoff {
            let target: RedactingURL
            let retryable: Bool
        }

        var sink = ""
        dump(Handoff(target: Self.pathBearing, retryable: false), to: &sink)

        #expect(!sink.isEmpty, "expected dump() to produce output at all")
        #expect(!sink.contains(Self.hexPathSecret))
        #expect(sink.contains(RedactingURL.redaction))
    }

    @Test("Mirror exposes no child carrying the token")
    func mirrorChildrenCarryNoToken() {
        let mirror = Mirror(reflecting: Self.tokenBearing)
        let rendered = mirror.children
            .map { "\($0.label ?? "-"): \($0.value)" }
            .joined(separator: "\n")

        #expect(!rendered.contains(Self.secret))
    }

    @Test("Mirror exposes no child carrying a path-embedded credential")
    func mirrorChildrenCarryNoPathSecret() {
        let mirror = Mirror(reflecting: Self.pathBearing)
        let rendered = mirror.children
            .map { "\($0.label ?? "-"): \($0.value)" }
            .joined(separator: "\n")

        #expect(!rendered.isEmpty, "expected the mirror to have children at all")
        #expect(!rendered.contains(Self.hexPathSecret))
        #expect(rendered.contains(RedactingURL.redaction))
    }

    @Test("Mirror exposes no URL at all, not even a partial one")
    func mirrorExposesNoURL() {
        let url = Self.tokenBearing

        // Both children of this mirror are derived from the rendered form, so
        // if the renderer returned an empty string the mirror would be empty
        // too and the loop below would pass without ever running its
        // assertion. Check the string and the child count first.
        #expect(!url.description.isEmpty, "expected a non-empty rendering to reflect on")
        let mirror = Mirror(reflecting: url)
        #expect(!mirror.children.isEmpty, "an empty mirror makes this test vacuous")

        for child in mirror.children {
            #expect(!(child.value is URL))
        }
    }

    @Test("Mirror exposes no URL for a path-embedded credential either")
    func mirrorExposesNoURLForPathSecret() {
        let url = Self.pathBearing

        #expect(!url.description.isEmpty, "expected a non-empty rendering to reflect on")
        let mirror = Mirror(reflecting: url)
        #expect(!mirror.children.isEmpty, "an empty mirror makes this test vacuous")

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

    @Test("read accessors report the parts, and path is the raw one")
    func safeAccessors() {
        let url = Self.tokenBearing

        #expect(url.scheme == "https")
        #expect(url.host == "live.example.invalid")
        #expect(url.path == "/stream/track.m3u8")

        // `path` is documented as a leak site on the same footing as
        // `resolvedURL`, not as a safe accessor beside `scheme` and `host`. It
        // hands back the credential the renderer withholds, so it must never be
        // the thing interpolated into a log line.
        #expect(Self.pathBearing.path == "/v1/stream/\(Self.hexPathSecret)/playback.m3u8")
        #expect(!Self.pathBearing.description.contains(Self.hexPathSecret))
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

    // MARK: - Path-embedded credentials
    //
    // `render` used to append `url.path` verbatim, so a URL whose credential
    // sat in the path instead of the query was classified as safe and printed
    // in full. Every case below is one that printed before.

    @Test("a credential in the first path segment is redacted")
    func pathSecretAsFirstSegment() {
        let url = RedactingURL(string: "https://live.example.invalid/\(Self.hexPathSecret)/v1/track.m3u8")!

        #expect(String(describing: url)
            == "https://live.example.invalid/<redacted>/v1/track.m3u8")
    }

    @Test("a credential in a middle path segment is redacted")
    func pathSecretInTheMiddle() {
        let url = RedactingURL(string: "https://live.example.invalid/v1/\(Self.hexPathSecret)/stream/playback.m3u8")!

        #expect(String(describing: url)
            == "https://live.example.invalid/v1/<redacted>/stream/playback.m3u8")
    }

    @Test("a credential in the last path segment, before the extension, is redacted")
    func pathSecretLastBeforeExtension() {
        let url = RedactingURL(string: "https://live.example.invalid/hls/live/\(Self.hexPathSecret)/playback.m3u8")!

        #expect(String(describing: url)
            == "https://live.example.invalid/hls/live/<redacted>/playback.m3u8")
        // The extension-bearing segment after it is untouched, which is the
        // point of judging segments one at a time.
        #expect(String(describing: url).hasSuffix("/<redacted>/playback.m3u8"))
    }

    @Test("a credential in the last, bare, path segment is redacted")
    func pathSecretAsLastBareSegment() {
        let url = RedactingURL(string: "https://live.example.invalid/hls/live/\(Self.hexPathSecret)")!

        #expect(String(describing: url) == "https://live.example.invalid/hls/live/<redacted>")
    }

    @Test("a credential segment keeps its extension, because the extension is not the credential")
    func pathSecretKeepsItsContentExtension() {
        let url = RedactingURL(string: "https://live.example.invalid/hls/live/\(Self.hexPathSecret).m3u8")!

        #expect(String(describing: url) == "https://live.example.invalid/hls/live/<redacted>.m3u8")
        #expect(!String(describing: url).contains(Self.hexPathSecret))
    }

    @Test("a base64 credential in the path is redacted")
    func base64PathSecretIsRedacted() {
        let url = RedactingURL(string: "https://live.example.invalid/v1/\(Self.base64PathSecret)/track.aac")!

        #expect(String(describing: url) == "https://live.example.invalid/v1/<redacted>/track.aac")
        #expect(!String(describing: url).contains(Self.base64PathSecret))
    }

    @Test("an all-caps credential in the path is redacted")
    func upperCasePathSecretIsRedacted() {
        let url = RedactingURL(string: "https://live.example.invalid/v1/\(Self.secret)/track.aac")!

        #expect(String(describing: url) == "https://live.example.invalid/v1/<redacted>/track.aac")
        #expect(!String(describing: url).contains(Self.secret))
    }

    @Test("a credential whose letters never spell a word is redacted")
    func letterRunlessPathSecretIsRedacted() {
        let url = RedactingURL(string: "https://live.example.invalid/v1/\(Self.runLessPathSecret)/track.aac")!

        #expect(String(describing: url) == "https://live.example.invalid/v1/<redacted>/track.aac")
        #expect(!String(describing: url).contains(Self.runLessPathSecret))
    }

    @Test("every credential in the path is redacted, not just the first")
    func everyPathSecretIsRedacted() {
        let url = RedactingURL(string:
            "https://live.example.invalid/v1/\(Self.hexPathSecret)/stream/\(Self.runLessPathSecret).m3u8")!

        #expect(String(describing: url)
            == "https://live.example.invalid/v1/<redacted>/stream/<redacted>.m3u8")
    }

    @Test("redacting the path leaves its shape alone")
    func pathShapeSurvivesRedaction() {
        // Checked against `redactedPath` rather than through a `URL`, because
        // whether `URL.path` keeps a trailing slash differs between
        // Foundation implementations and this app does not depend on the
        // difference — the redaction itself must not be what normalises it.
        #expect(RedactingURL.redactedPath("/v1/\(Self.hexPathSecret)/") == "/v1/<redacted>/")
        #expect(RedactingURL.redactedPath("/v1//\(Self.hexPathSecret)") == "/v1//<redacted>")
        #expect(RedactingURL.redactedPath("/") == "/")
        #expect(RedactingURL.redactedPath("") == "")

        let doubled = RedactingURL(string: "https://live.example.invalid/v1//\(Self.hexPathSecret)")!
        #expect(String(describing: doubled) == "https://live.example.invalid/v1//<redacted>")
    }

    @Test("a path credential and a query credential are both redacted")
    func pathAndQuerySecretsAreBothRedacted() {
        let url = RedactingURL(string:
            "https://live.example.invalid/v1/\(Self.hexPathSecret)/track.m3u8?token=\(Self.secret)")!

        #expect(String(describing: url)
            == "https://live.example.invalid/v1/<redacted>/track.m3u8?<redacted>")
    }

    @Test("the sensitive-component flag is true for a path credential in any position")
    func pathSecretIsSensitive() {
        let candidates = [
            "https://live.example.invalid/\(Self.hexPathSecret)/v1/track.m3u8",
            "https://live.example.invalid/v1/\(Self.hexPathSecret)/stream/playback.m3u8",
            "https://live.example.invalid/hls/live/\(Self.hexPathSecret)/playback.m3u8",
            "https://live.example.invalid/hls/live/\(Self.hexPathSecret)",
            "https://live.example.invalid/hls/live/\(Self.hexPathSecret).m3u8",
            "https://live.example.invalid/v1/\(Self.base64PathSecret)/track.aac",
            "https://live.example.invalid/v1/\(Self.secret)/track.aac",
            "https://live.example.invalid/v1/\(Self.runLessPathSecret)/track.aac"
        ]

        for candidate in candidates {
            let url = RedactingURL(string: candidate)!
            #expect(url.carriesSensitiveComponents, "expected \(candidate) to be flagged")
        }
    }

    @Test("the flag is exactly the set of components that were replaced")
    func sensitiveFlagMatchesWhatWasRedacted() {
        let candidates = [
            "https://live.example.invalid/v1/track.m3u8",
            "https://live.example.invalid/v1/segment-000012.aac",
            "https://live.example.invalid/rest/v2/experience/modules/modify/authentication",
            "https://live.example.invalid/v1/\(Self.hexPathSecret)/track.m3u8",
            "https://live.example.invalid/v1/track.m3u8?consumer=k2",
            "https://live.example.invalid/v1/track.m3u8#now"
        ]

        for candidate in candidates {
            let url = RedactingURL(string: candidate)!
            let wasRedacted = String(describing: url).contains(RedactingURL.redaction)
            #expect(url.carriesSensitiveComponents == wasRedacted, "flag disagrees with \(candidate)")
        }
    }

    @Test("every description path is closed for a path credential")
    func pathSecretIsClosedOnEveryDescriptionPath() {
        struct Holder {
            let target: RedactingURL
        }

        let url = Self.pathBearing
        let renderings = [
            String(describing: url),
            String(reflecting: url),
            "GET \(url) failed",
            String(describing: Holder(target: url)),
            String(reflecting: Holder(target: url)),
            String(describing: [url]),
            String(reflecting: [url]),
            String(describing: [url: url]),
            String(reflecting: Optional.some(url) as Any),
            String(reflecting: url as Any)
        ]

        for rendered in renderings {
            #expect(!rendered.isEmpty, "a rendering that produced nothing guards nothing")
            #expect(!rendered.contains(Self.hexPathSecret))
        }
    }

    @Test("redaction is presentational: the address still carries the path credential")
    func redactionDoesNotChangeTheAddress() {
        let url = Self.pathBearing

        #expect(url.resolvedURL.absoluteString.contains(Self.hexPathSecret))
        #expect(url.path == "/v1/stream/\(Self.hexPathSecret)/playback.m3u8")
        #expect(!url.description.contains(Self.hexPathSecret))
    }

    // MARK: - The classification rule, stated and tested

    @Test("the rule is a length floor and three lexical escapes")
    func classificationRuleIsStated() {
        // Opaque: past the floor, and not spelled.
        #expect(RedactingURL.isOpaque("9f3c1b7e2a4d"))     // hex, no word in it
        #expect(RedactingURL.isOpaque("Zm9vYmFyYmF6cXV4"))  // base64, mixed case
        #expect(RedactingURL.isOpaque("SECRETTOKENVALUE"))   // all caps
        #expect(RedactingURL.isOpaque("qm9x8k2zp4nr"))      // letters never spell a word
        #expect(RedactingURL.isOpaque("deadbeefcafe"))      // all hex despite a long run

        // Structural: under the floor, or spelled.
        #expect(!RedactingURL.isOpaque("v1"))
        #expect(!RedactingURL.isOpaque("playback"))
        #expect(!RedactingURL.isOpaque("channel-17"))
        #expect(!RedactingURL.isOpaque("authentication"))   // 14 characters, all lower
        #expect(!RedactingURL.isOpaque("subscriptions"))    // 13 characters, all lower
        #expect(!RedactingURL.isOpaque("segment-000012"))   // 13 characters, spells something
        #expect(!RedactingURL.isOpaque("bitrate-128000"))
    }

    @Test("the floor is the boundary, and it is the rule's own constant")
    func classificationFloorIsExact() {
        #expect(RedactingURL.minimumOpaqueLength == 12)

        // A hex digest one character under the floor is left alone…
        #expect("abcdefabcde".count == RedactingURL.minimumOpaqueLength - 1)
        #expect(!RedactingURL.isOpaque("abcdefabcde"))
        // …and the same digest on the floor is not.
        #expect(RedactingURL.isOpaque("abcdefabcdef"))
    }

    @Test("only a known content extension is peeled off before judging")
    func onlyKnownExtensionsArePeeled() {
        // A known extension is kept even when the core beside it is replaced.
        #expect(RedactingURL.redactedPath("/a/9f3c1b7e2a4d.m3u8") == "/a/<redacted>.m3u8")
        // An unknown one is not, so the whole segment is judged and the
        // extension goes with it.
        #expect(RedactingURL.redactedPath("/a/9f3c1b7e2a4d.bin") == "/a/<redacted>")
        // Only the last extension is peeled; an earlier dot stays in the core.
        #expect(RedactingURL.redactedPath("/a/segment.part00001.ts") == "/a/segment.part00001.ts")
    }

    @Test("a path with no secret in it renders in full")
    func ordinaryPathsRenderInFull() {
        // Every address this app actually builds, plus the CDN shapes the
        // probe observed. None of them may be touched by the path rule.
        let addresses = [
            "https://api.edge-gateway.siriusxm.com/session/v1/sessions/refresh",
            "https://api.edge-gateway.siriusxm.com/profile/v4/profiles/me",
            "https://api.edge-gateway.siriusxm.com/subscription/v1/subscriptions",
            "https://player.siriusxm.com/rest/v2/experience/modules/modify/authentication",
            "https://player.siriusxm.com/rest/v2/experience/modules/resume",
            "https://www.siriusxm.com/player",
            "https://live-1.streaming.siriusxm.com/hls/v1/channel-17/master.m3u8",
            "https://live-1.streaming.siriusxm.com/hls/v1/channel-17/segment-000012.aac",
            "https://live-1.streaming.siriusxm.com/hls/v1/channel-17/segment.part00001.ts",
            "https://images.example.invalid/art/channel-17.jpg",
            "https://images.example.invalid/art/channel-17-1280x1280.jpg"
        ]

        for address in addresses {
            let url = RedactingURL(string: address)!
            #expect(String(describing: url) == address, "over-redacted \(address)")
            #expect(!url.carriesSensitiveComponents, "wrongly flagged \(address)")
        }
    }

    @Test("a query credential does not cost the path its rendering")
    func queryRedactionLeavesThePathAlone() {
        let url = RedactingURL(string:
            "https://live-1.streaming.siriusxm.com/hls/v1/channel-17/master.m3u8?consumer=k2&token=\(Self.secret)")!

        #expect(String(describing: url)
            == "https://live-1.streaming.siriusxm.com/hls/v1/channel-17/master.m3u8?<redacted>")
        #expect(url.carriesSensitiveComponents)
    }

    @Test("a URL with no path renders without one")
    func emptyPathIsLeftAlone() {
        let url = RedactingURL(string: "https://player.siriusxm.com")!

        #expect(RedactingURL.redactedPath("") == "")
        #expect(String(describing: url) == "https://player.siriusxm.com")
        #expect(!url.carriesSensitiveComponents)
    }
}
