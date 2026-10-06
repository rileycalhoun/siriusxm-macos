import Foundation

/// A URL that is allowed to carry a token and is therefore never allowed to
/// render one.
///
/// SiriusXM media requests put credentials in the query string, so a plain
/// `URL` is a loaded gun: `print(url)`, `"\(url)"`, `String(describing:)` of a
/// struct that holds one, and the `debugDescription` of a `Set` that contains
/// one all end up in a log, a crash report, or an issue template. This type
/// closes those paths by rendering the scheme, host, and path and replacing
/// everything else with `<redacted>`.
///
/// The path is not a safe zone. A signed-media gateway is free to put the
/// credential in the path instead of the query — `/v1/stream/<id>/playback.m3u8`
/// — and a renderer that appends `url.path` verbatim publishes it. So the path
/// is rendered segment by segment, and a segment that reads as an opaque
/// credential is replaced even though nothing else about the URL changed. The
/// rule is `isOpaque(_:)` below: stated, deterministic, and testable, and
/// deliberately conservative about the ordinary words a real path is made of.
///
/// That rendering list is the complete list of *description* paths, and it is
/// not the complete list of ways to get a string out of this type. Reflection
/// — `dump()` and `Mirror` — does not consult the description protocols at
/// all; it walks stored properties, so it prints the private `url` in full,
/// token and all. That path is closed by `CustomReflectable` below, which is a
/// separate conformance for a separate reason, not a third description.
///
/// Three deliberate omissions:
///
///   - It is not `Codable`. Encoding is how a token-bearing URL reaches disk.
///   - It is not `RawRepresentable`. A `rawValue` is one accessor away from
///     being interpolated.
///   - It has no public initialiser from a rendered string. Nothing in this app
///     parses a URL back out of text.
///
/// `resolvedURL` is the single escape hatch, and it exists because something
/// downstream genuinely has to open the URL. Keep it on the right-hand side of
/// an assignment that goes straight into a request. `path` is the second one,
/// for the same reason, and is documented as such.
public struct RedactingURL: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// What every sensitive component renders as.
    public static let redaction = "<redacted>"

    /// Rendered when a URL cannot be taken apart at all. Losing the value is
    /// always preferable to rendering a value that might contain a token.
    public static let unrenderable = "<unrenderable-url>"

    /// The shortest a path segment may be before it is even considered for
    /// redaction. Internal, so the rule can be named in a test rather than
    /// restated as a magic number.
    static let minimumOpaqueLength = 12

    private let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url)
    }

    // MARK: - The escape hatches

    /// The underlying URL, for handing to a request builder or a player.
    ///
    /// Treat every use of this as a leak site: the value it returns must go
    /// somewhere that treats it as opaque.
    public var resolvedURL: URL { url }

    /// The raw path, unredacted.
    ///
    /// This is a **leak site on the same footing as `resolvedURL`**, not a
    /// safe accessor alongside `scheme` and `host`. It exists because route
    /// matching and request building genuinely need the path, and it returns
    /// the value the renderer above exists to withhold — a path may embed the
    /// credential. Log `description`, never `path`.
    public var path: String { url.path }

    // MARK: - Safe to log, read, or group by

    public var scheme: String? { url.scheme }

    public var host: String? { url.host }

    public var port: Int? { url.port }

    /// True when this URL carries anything that must never be rendered: a
    /// query, a fragment, embedded credentials, or a path segment the
    /// renderer would replace.
    ///
    /// This is exactly the set of components `render` replaces, so it is true
    /// if and only if something was redacted — including a secret sitting in
    /// the path, which is the case this property used to miss.
    ///
    /// Callers that want to be loud about it can assert on this in debug
    /// builds; it is the cheapest possible way to notice that a URL which
    /// should have been token-free has picked up a query string.
    public var carriesSensitiveComponents: Bool {
        url.query != nil
            || url.fragment != nil
            || url.user != nil
            || url.password != nil
            || Self.redactedPath(url.path) != url.path
    }

    // MARK: - Rendering

    public var description: String { Self.render(url) }

    public var debugDescription: String { description }

    /// Builds the printable form from parts read individually, rather than
    /// from `absoluteString`, so there is exactly one place in the codebase
    /// where a URL becomes text.
    static func render(_ url: URL) -> String {
        guard let scheme = url.scheme else { return unrenderable }

        var text = "\(scheme)://"
        if url.user != nil || url.password != nil {
            text += "\(redaction)@"
        }
        if let host = url.host, !host.isEmpty {
            text += host
            if let port = url.port {
                text += ":\(port)"
            }
        }
        text += redactedPath(url.path)
        if url.query != nil {
            text += "?\(redaction)"
        }
        if url.fragment != nil {
            text += "#\(redaction)"
        }
        return text
    }

    // MARK: - Path segment classification

    /// Extensions that name a *kind of content*, not a credential.
    ///
    /// A segment ending in one of these is judged on its core, so
    /// `/v1/stream/<blob>/playback.m3u8` keeps saying "manifest" even when the
    /// blob beside it is replaced.
    private static let contentExtensions: Set<String> = [
        // Media. HLS is three of these; the rest are what a CDN might hand back.
        "m3u8", "ts", "aac", "m4a", "m4s", "mp3", "mp4", "aif", "aiff", "wav",
        // Images.
        "jpg", "jpeg", "png", "gif", "webp", "svg",
        // Text and scripts.
        "json", "txt", "html", "htm", "xml", "css", "js", "vtt", "key"
    ]

    /// The path as it may be printed: every opaque segment replaced by
    /// `redaction`, every other segment byte-for-byte unchanged.
    ///
    /// Splitting on `/` and rejoining on `/` reproduces the input exactly when
    /// nothing is redacted, so a leading slash, an empty segment and a
    /// trailing slash all survive untouched.
    static func redactedPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { redactedSegment(String($0)) }
            .joined(separator: "/")
    }

    /// One path segment, redacted if and only if its core is opaque.
    ///
    /// When the segment is opaque *and* ends in a known content extension, the
    /// extension is kept: `9f3c1b7e2a4d.m3u8` renders as `<redacted>.m3u8`,
    /// because a log line that still says "manifest" is worth more than one
    /// that says nothing at all.
    private static func redactedSegment(_ segment: String) -> String {
        guard let dot = segment.lastIndex(of: "."), dot != segment.startIndex else {
            return isOpaque(segment) ? redaction : segment
        }
        guard contentExtensions.contains(
            segment[segment.index(after: dot)...].lowercased()
        ) else {
            return isOpaque(segment) ? redaction : segment
        }
        guard isOpaque(String(segment[..<dot])) else { return segment }
        return redaction + segment[dot...]
    }

    /// True when a path segment's core reads as a blob no person typed.
    ///
    /// The rule, in full:
    ///
    ///   1. The core is the segment minus a trailing content extension
    ///      (`.m3u8`, `.aac`, `.jpg`, …), or the whole segment when it has no
    ///      such extension.
    ///   2. A core shorter than `minimumOpaqueLength` characters is
    ///      structural, full stop. Every route word this app knows is shorter
    ///      than the floor — `v1`, `player`, `sessions`, `playback`,
    ///      `channel-17` — so ordinary paths are never even considered, and
    ///      short path components are never at risk.
    ///   3. A core at or over the floor is opaque unless all three of these
    ///      hold, which together mean "somebody wrote this down":
    ///
    ///        - it contains no uppercase ASCII letter — `authentication` is
    ///          14 characters long and survives on this clause alone;
    ///        - it is not entirely hexadecimal — `deadbeefcafe` has one run of
    ///          eight lowercase letters and is still a digest;
    ///        - it spells something: some run of four or more lowercase
    ///          letters, where a random blob's letters arrive in runs too short
    ///          to be a word (`9f3c1b7e2a4d`, `abc123def456`).
    ///
    /// Between them the three clauses catch a hex digest (all hex), a base64
    /// or UUID blob (mixed case, or letters in runs too short), and an
    /// all-caps token (uppercase). A path segment is none of those things.
    ///
    /// Deliberately conservative, and the trade is named: a path secret shorter
    /// than 12 characters, or one that happens to be spelled in lowercase
    /// words, is *not* caught. Every credential this app actually holds — a
    /// bearer token, a gupId, an `SXMAKTOKEN` — is far longer than the floor
    /// and is not word-shaped, and the query redaction above is the belt to
    /// this braces. A rule loose enough to catch every possible short secret
    /// would have to redact `authentication`.
    static func isOpaque(_ core: String) -> Bool {
        guard core.count >= minimumOpaqueLength else { return false }
        if core.contains(where: { $0.isASCII && $0.isUppercase }) { return true }
        if core.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return true }
        return longestLowercaseRun(of: core) < 4
    }

    /// Length of the longest run of consecutive ASCII lowercase letters.
    ///
    /// A word has one. `9f3c1b7e2a4d` has none longer than one, `abc123def456`
    /// has three, `playback0abc1234` has eight.
    private static func longestLowercaseRun(of core: String) -> Int {
        var longest = 0
        var current = 0
        for character in core {
            if character.isASCII, character.isLowercase {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

// MARK: - Reflection

extension RedactingURL: CustomReflectable {
    /// `dump()` and `Mirror` bypass `description` and `debugDescription`
    /// entirely and walk stored properties. Without this the private `url` is
    /// printed verbatim, query string and opaque path segment included, which
    /// is the one leak the two description protocols cannot close.
    ///
    /// The mirror therefore carries no `URL` at all — not a redacted one, not
    /// a partial one, none. It carries only the rendered form, which is built
    /// part by part and already proven safe, and the flag saying whether this
    /// URL had anything sensitive to redact in the first place. Both of those
    /// now go through `redactedPath`, so a path-embedded credential is closed
    /// here by the same route a query credential is.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "rendered": description,
            "carriesSensitiveComponents": carriesSensitiveComponents
        ])
    }
}
