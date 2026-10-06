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
/// an assignment that goes straight into a request.
public struct RedactingURL: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// What every sensitive component renders as.
    public static let redaction = "<redacted>"

    /// Rendered when a URL cannot be taken apart at all. Losing the value is
    /// always preferable to rendering a value that might contain a token.
    public static let unrenderable = "<unrenderable-url>"

    private let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url)
    }

    // MARK: - The one escape hatch

    /// The underlying URL, for handing to a request builder or a player.
    ///
    /// Treat every use of this as a leak site: the value it returns must go
    /// somewhere that treats it as opaque.
    public var resolvedURL: URL { url }

    // MARK: - Safe to log, read, or group by

    public var scheme: String? { url.scheme }

    public var host: String? { url.host }

    public var path: String { url.path }

    public var port: Int? { url.port }

    /// True when this URL carries anything that must never be rendered:
    /// a query, a fragment, or embedded credentials.
    ///
    /// Callers that want to be loud about it can assert on this in debug
    /// builds; it is the cheapest possible way to notice that a URL which
    /// should have been token-free has picked up a query string.
    public var carriesSensitiveComponents: Bool {
        url.query != nil || url.fragment != nil || url.user != nil || url.password != nil
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
        text += url.path
        if url.query != nil {
            text += "?\(redaction)"
        }
        if url.fragment != nil {
            text += "#\(redaction)"
        }
        return text
    }
}

// MARK: - Reflection

extension RedactingURL: CustomReflectable {
    /// `dump()` and `Mirror` bypass `description` and `debugDescription`
    /// entirely and walk stored properties. Without this the private `url` is
    /// printed verbatim, query string included, which is the one leak the two
    /// description protocols cannot close.
    ///
    /// The mirror therefore carries no `URL` at all — not a redacted one, not
    /// a partial one, none. It carries only the rendered form, which is built
    /// part by part and already proven safe, and the flag saying whether this
    /// URL had anything sensitive to redact in the first place.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "rendered": description,
            "carriesSensitiveComponents": carriesSensitiveComponents
        ])
    }
}
