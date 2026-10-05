import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a request never produced an HTTP response.
enum TransportFailure: Error, Sendable, CustomStringConvertible {
    case timedOut
    case networkUnreachable
    case hostUnreachable
    case redirectRefused
    case cancelled
    case tlsFailure
    case other(String)

    init(_ error: URLError) {
        switch error.code {
        case .timedOut:
            self = .timedOut
        case .notConnectedToInternet, .networkConnectionLost:
            self = .networkUnreachable
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            self = .hostUnreachable
        case .cancelled:
            self = .cancelled
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateUntrusted,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            self = .tlsFailure
        default:
            self = .other(String(describing: error.code.rawValue))
        }
    }

    var description: String {
        switch self {
        case .timedOut: return "timed-out"
        case .networkUnreachable: return "network-unreachable"
        case .hostUnreachable: return "host-unreachable"
        case .redirectRefused: return "redirect-refused"
        case .cancelled: return "cancelled"
        case .tlsFailure: return "tls-failure"
        case .other(let detail): return "other(\(Redactor.sanitize(detail)))"
        }
    }
}

/// One `Set-Cookie` header field. The value is stored because the protocol
/// layer needs it, and is never rendered.
struct HTTPCookieField: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let name: String
    let value: String

    var description: String { "\(name)=<redacted>" }
    var debugDescription: String { "\(name)=<redacted>" }
}

/// The outcome of a single HTTP exchange.
///
/// Knows nothing about SiriusXM. Anything protocol-specific is decided by
/// the caller from `statusCode`, `body`, and `cookies`.
struct HTTPResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// `0` means no response arrived; read `transportFailure` for the reason.
    let statusCode: Int
    let contentType: String?
    let body: String
    let cookies: [HTTPCookieField]
    let transportFailure: TransportFailure?

    init(
        statusCode: Int,
        contentType: String?,
        body: String,
        cookies: [HTTPCookieField],
        transportFailure: TransportFailure?
    ) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.cookies = cookies
        self.transportFailure = transportFailure
    }

    var isEmptyBody: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Coarse, secret-free classification of the payload, safe to print.
    var bodyShape: String {
        if isEmptyBody { return "empty" }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return "json" }
        if trimmed.hasPrefix("<") { return "markup" }
        return "opaque"
    }

    var description: String {
        let status = statusCode == 0 ? "-" : String(statusCode)
        return "HTTPResult(status: \(status), contentType: \(contentType ?? "-"), body: \(bodyShape), cookies: \(cookies.count), transport: \(transportFailure?.description ?? "none"))"
    }

    var debugDescription: String { description }
}

/// URLSession transport with no cookie jar, no cache, no credential storage,
/// and no redirects.
///
/// Cookies are read straight off the response headers by
/// `EphemeralHTTPClient.cookieFields(from:)` rather than by the shared
/// `HTTPCookieStorage`. That is deliberate: it keeps the two credential-gated
/// probe steps from accidentally sharing a jar, and it makes every cookie the
/// probe ever sees visible to the caller as a plain value.
final class EphemeralHTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = EphemeralHTTPClient()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// Sends one request and hands back the status and the body. Never
    /// throws: transport failures come back as a `HTTPResult` so the probe
    /// driver can record them alongside every other outcome.
    func send(_ request: URLRequest) async -> HTTPResult {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return HTTPResult(
                    statusCode: 0,
                    contentType: nil,
                    body: "",
                    cookies: [],
                    transportFailure: .other("non-HTTP-response")
                )
            }
            return HTTPResult(
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                body: String(decoding: data, as: UTF8.self),
                cookies: Self.cookieFields(from: http),
                transportFailure: nil
            )
        } catch let urlError as URLError {
            return HTTPResult(
                statusCode: 0,
                contentType: nil,
                body: "",
                cookies: [],
                transportFailure: TransportFailure(urlError)
            )
        } catch {
            return HTTPResult(
                statusCode: 0,
                contentType: nil,
                body: "",
                cookies: [],
                transportFailure: .other("unclassified-error")
            )
        }
    }

    /// Refuses every redirect. A redirect that silently moves a credentialed
    /// request to another host is a credential-exfiltration bug, so the
    /// probe stops instead of following.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    // MARK: - Set-Cookie extraction

    static func cookieFields(from response: HTTPURLResponse) -> [HTTPCookieField] {
        cookieFields(fromHeader: response.value(forHTTPHeaderField: "Set-Cookie") ?? "")
    }

    /// Same as `cookieFields(from:)`, but takes the already-folded header
    /// string so the tests can drive the parser without a network.
    ///
    /// A `Set-Cookie` field is `name=value; Attribute; Attribute`. The
    /// attributes are dropped: everything from the first `;` is server-side
    /// metadata, and replaying it in a `Cookie:` request header would be
    /// wrong. A field with no `=` at all is not a cookie and is discarded.
    static func cookieFields(fromHeader header: String) -> [HTTPCookieField] {
        guard !header.isEmpty else { return [] }
        return splitSetCookieHeader(header).compactMap { piece in
            guard let equals = piece.firstIndex(of: "=") else { return nil }

            let name = piece[piece.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            let remainder = piece[piece.index(after: equals)...]
            let attributes = remainder.firstIndex(of: ";")
            let rawValue = attributes.map { remainder[remainder.startIndex..<$0] } ?? remainder

            return HTTPCookieField(
                name: String(name),
                value: String(rawValue).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// Splits a folded `Set-Cookie` header into individual cookies.
    ///
    /// URLSession folds repeated headers into one comma-joined string, so a
    /// naive `split(separator: ",")` corrupts any cookie carrying an
    /// `Expires` attribute. A comma is treated as a cookie boundary only
    /// when the text after it looks like `name=…`, which is never true for
    /// the `Mon, 12 Oct 2026 07:28:00 GMT` form.
    static func splitSetCookieHeader(_ header: String) -> [String] {
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
        // `prefix=<token>,x=1` from being torn in half: the comma inside the
        // value is not followed by whitespace.
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