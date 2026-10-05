import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one thing the rest of the app is allowed to ask of the network.
///
/// A protocol rather than a concrete type so that the retry policy, the
/// session refresher, and every test can be driven by a scripted transport
/// without a socket. Everything above this line is written against
/// `HTTPRequestSpec` and `HTTPResponsePayload`, neither of which mentions a
/// SiriusXM host.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload
}

/// `URLSession` transport with no cookie jar, no cache, no credential
/// storage, and no redirects.
///
/// Redirects are refused rather than followed. A redirect that moves a
/// credentialed request to another host is a credential-exfiltration bug, and
/// the transport has no way to know which hosts the user already trusts.
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    /// Built lazily because the delegate is `self`, and a subclass cannot
    /// pass `self` to `URLSession` before `super.init()` has run.
    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.configuration = configuration
        super.init()
    }

    /// Throws `TransportError` rather than a `URLError`, so no caller ever
    /// has a `URLError` to print.
    public func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload {
        var urlRequest = URLRequest(url: request.url.resolvedURL)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        for header in request.headers {
            urlRequest.setValue(header.resolvedValue, forHTTPHeaderField: header.name)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.unclassified(code: -1)
            }
            return HTTPResponsePayload(
                statusCode: http.statusCode,
                headers: Self.headers(from: http),
                body: data
            )
        } catch let urlError as URLError {
            throw TransportError(urlError)
        }
    }

    /// Refuses every redirect.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    static func headers(from response: HTTPURLResponse) -> [HTTPHeader] {
        response.allHeaderFields.reduce(into: [HTTPHeader]()) { headers, field in
            guard let name = field.key as? String else { return }
            let value = String(describing: field.value)
            headers.append(
                HTTPHeader(
                    name,
                    value: value,
                    // `Set-Cookie` and `Authorization` are covered by name;
                    // everything else arriving from a server is treated as
                    // potentially carrying a credential unless it is one of
                    // the small set of structural fields a retry needs to read.
                    sensitivity: HTTPHeader.structuralNames.contains(name.lowercased()) ? .plain : .sensitive
                )
            )
        }
    }
}

extension HTTPHeader {
    /// The only response fields this app is willing to render or reason about.
    static let structuralNames: Set<String> = [
        "content-type",
        "content-length",
        "retry-after",
        "date",
        "etag",
        "last-modified"
    ]
}

/// Parses a folded `Set-Cookie` header into its individual fields.
///
/// This is HTTP grammar, so it lives in the transport rather than in
/// `SiriusXMProtocol`. Which cookie names are meaningful is protocol
/// knowledge and stays there.
public enum SetCookieHeaderParser {
    /// A `Set-Cookie` field is `name=value; Attribute; Attribute`. Attributes
    /// are dropped: everything from the first `;` is server-side metadata and
    /// replaying it in a `Cookie:` request header would be wrong. A field with
    /// no `=` is not a cookie and is discarded.
    public static func fields(fromHeader header: String) -> [HTTPHeader] {
        guard !header.isEmpty else { return [] }
        return split(header).compactMap { piece in
            guard let equals = piece.firstIndex(of: "=") else { return nil }

            let name = piece[piece.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            let remainder = piece[piece.index(after: equals)...]
            let attributes = remainder.firstIndex(of: ";")
            let rawValue = attributes.map { remainder[remainder.startIndex..<$0] } ?? remainder

            return HTTPHeader(
                String(name),
                value: String(rawValue).trimmingCharacters(in: .whitespaces),
                // Every cookie value is a credential until proven otherwise.
                sensitivity: .sensitive
            )
        }
    }

    /// Splits a folded `Set-Cookie` header into individual cookies.
    ///
    /// URLSession folds repeated headers into one comma-joined string, so a
    /// naive `split(separator: ",")` corrupts any cookie carrying an
    /// `Expires` attribute. A comma is a cookie boundary only when the text
    /// after it looks like `name=`, which is never true for the
    /// `Mon, 12 Oct 2026 07:28:00 GMT` form.
    public static func split(_ header: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var index = header.startIndex

        while index < header.endIndex {
            let character = header[index]
            if character == "," {
                let remainder = header.index(after: index)
                if isCookieBoundary(header, from: remainder) {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { pieces.append(trimmed) }
                    current = ""
                    index = remainder
                    continue
                }
            }
            current.append(character)
            index = header.index(after: index)
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(trimmed) }
        return pieces
    }

    private static func isCookieBoundary(_ header: String, from index: String.Index) -> Bool {
        var cursor = index

        // A folded `Set-Cookie` is joined with ", ", so require at least one
        // space after the comma. This is what stops a cookie value such as
        // `prefix=<token>,x=1` from being torn in half.
        var spaces = 0
        while cursor < header.endIndex, header[cursor] == " " {
            cursor = header.index(after: cursor)
            spaces += 1
        }
        guard spaces > 0 else { return false }

        let nameStart = cursor
        while cursor < header.endIndex, header[cursor] != "=", header[cursor] != ";" {
            cursor = header.index(after: cursor)
        }

        // No `=` before the end of the header means this comma belonged to
        // something else, such as an `Expires` date.
        guard cursor < header.endIndex, header[cursor] == "=" else { return false }

        let name = header[nameStart..<cursor].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return name.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
                || character == "-" || character == "."
        }
    }
}
