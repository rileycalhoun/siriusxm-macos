import Foundation

/// Why a request never produced an HTTP response.
///
/// Reduced to a closed set of slugs. A raw `URLError` is never stored, because
/// its `localizedDescription` routinely contains a URL.
public enum TransportError: Error, Sendable, Hashable, CustomStringConvertible {
    case timedOut
    case networkUnreachable
    case hostUnreachable
    case redirectRefused
    case cancelled
    case tlsFailure
    case unclassified(code: Int)

    public init(_ error: URLError) {
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
            self = .unclassified(code: error.code.rawValue)
        }
    }

    /// A cancelled request is the caller's own doing and is never retried.
    public var isCancellation: Bool { self == .cancelled }

    /// Whether trying the same request again has a plausible chance of
    /// working. Host and TLS failures are excluded: retrying a name that does
    /// not resolve or a certificate that does not validate is how an app ends
    /// up hammering a service it cannot reach.
    public var isWorthRetrying: Bool {
        switch self {
        case .timedOut, .networkUnreachable: return true
        case .hostUnreachable, .redirectRefused, .cancelled, .tlsFailure, .unclassified: return false
        }
    }

    public var description: String {
        switch self {
        case .timedOut: return "timed-out"
        case .networkUnreachable: return "network-unreachable"
        case .hostUnreachable: return "host-unreachable"
        case .redirectRefused: return "redirect-refused"
        case .cancelled: return "cancelled"
        case .tlsFailure: return "tls-failure"
        case .unclassified(let code): return "unclassified(\(code))"
        }
    }
}

/// The outcome of one HTTP exchange.
///
/// Knows nothing about SiriusXM. Everything protocol-specific is decided by
/// the caller from `statusCode` and `resolvedBody`.
public struct HTTPResponsePayload: Sendable, Hashable {
    public let statusCode: Int
    public let headers: [HTTPHeader]
    private let body: Data

    public init(statusCode: Int, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// The single escape hatch, for handing to the parser that knows what the
    /// body means.
    public var resolvedBody: Data { body }

    /// Rendered body shape: enough to tell "the server sent an error page" from
    /// "the server sent nothing", with nothing from the body itself.
    public var bodyShape: String {
        guard !body.isEmpty else { return "empty" }
        let trimmed = String(decoding: body.prefix(1), as: UTF8.self)
        switch trimmed {
        case "{", "[": return "json"
        case "<": return "markup"
        default: return "opaque"
        }
    }

    public func header(_ name: String) -> HTTPHeader? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The edge gateway answers 401 when a session has gone. Declared here as
    /// an HTTP fact, not as a protocol fact: this module does not know which
    /// generation uses it, only that it is a status code.
    public var isUnauthorized: Bool { statusCode == 401 }

    public var isRetryableStatus: Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    /// Seconds requested by `Retry-After`, if the server sent one.
    ///
    /// Accepts both forms HTTP defines: a count of seconds, and an HTTP date.
    /// A date in the past yields `0`, which the policy treats as "retry now".
    /// An unparseable value yields `nil`, which the policy treats as "no
    /// instruction" rather than "retry immediately".
    public var retryAfterSeconds: Int? {
        guard let raw = header("Retry-After")?.resolvedValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(trimmed), seconds >= 0 { return seconds }

        guard let date = HTTPDateParser.date(from: trimmed) else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? Int(interval.rounded(.up)) : 0
    }

    public var description: String {
        "HTTP \(statusCode) (\(body.count) bytes, \(bodyShape), \(headers.count) headers)"
    }
}

extension HTTPResponsePayload: CustomStringConvertible {}

/// HTTP-date parsing, isolated so the two grammars have one home.
enum HTTPDateParser {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
