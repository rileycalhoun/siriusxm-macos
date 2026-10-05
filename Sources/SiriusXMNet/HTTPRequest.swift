import Foundation

/// The HTTP verbs this app uses. An enum rather than a string so that a
/// typo cannot become a request.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case head = "HEAD"
}

/// Whether a header value is allowed to be rendered.
///
/// `.plain` headers may appear in a log line verbatim. `.sensitive` ones may
/// not, and `description` renders them as `name: <redacted>` regardless of
/// whether anyone remembered to mark them.
public enum HeaderValueSensitivity: Sendable, Hashable {
    case plain
    case sensitive
}

/// One header field.
///
/// The value is stored because the request builder needs it, and it is never
/// rendered. Marking a field `.sensitive` is the caller's job for
/// app-specific headers; the four credential-bearing fields that HTTP itself
/// defines are always treated as sensitive, so a plain `Authorization` cannot
/// be logged by omission.
public struct HTTPHeader: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Field names that carry credentials by definition, not by convention.
    ///
    /// This list is HTTP vocabulary, not SiriusXM vocabulary. Which
    /// app-specific header holds a token is decided in `SiriusXMProtocol`,
    /// which marks those fields `.sensitive` at construction.
    public static let alwaysSensitiveNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie"
    ]

    public let name: String
    private let value: String
    public let sensitivity: HeaderValueSensitivity

    public init(_ name: String, value: String, sensitivity: HeaderValueSensitivity = .plain) {
        self.name = name
        self.value = value
        self.sensitivity = HTTPHeader.alwaysSensitiveNames.contains(name.lowercased())
            ? .sensitive
            : sensitivity
    }

    /// The single escape hatch, for handing to `URLRequest`.
    public var resolvedValue: String { value }

    public var isSensitive: Bool { sensitivity == .sensitive }

    public var description: String {
        isSensitive ? "\(name): <redacted>" : "\(name): \(value)"
    }

    public var debugDescription: String { description }
}

/// A request, described without giving the transport anything to interpret.
///
/// `SiriusXMNet` never looks at the path to decide what to do with it. The
/// protocol module builds one of these and hands it over; the transport sends
/// it. That separation is what keeps hostnames, paths, and header names out of
/// the transport and lets the retry policy be reasoned about on its own.
public struct HTTPRequestSpec: Sendable, Hashable {
    public let method: HTTPMethod
    /// A `RedactingURL`, not a `URL`. SiriusXM media requests carry the token
    /// in the query string, so the type that holds a request URL is the type
    /// that has to be safe to print in an array of pending requests.
    public let url: SiriusXMCore.RedactingURL
    public let headers: [HTTPHeader]
    public let body: Data?
    /// Overrides the session default for this one request.
    public let timeout: TimeInterval?

    public init(
        method: HTTPMethod,
        url: SiriusXMCore.RedactingURL,
        headers: [HTTPHeader] = [],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Header lookup by case-insensitive name, as HTTP defines it.
    public func header(_ name: String) -> HTTPHeader? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Never renders a URL query or a header value.
    public var description: String {
        let renderedHeaders = headers.map(\.description).joined(separator: ", ")
        let bodyNote = body.map { "\($0.count) bytes" } ?? "no body"
        return "\(method.rawValue) \(url) [\(renderedHeaders)] (\(bodyNote))"
    }
}

extension HTTPRequestSpec: CustomStringConvertible {}
