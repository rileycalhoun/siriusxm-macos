import Foundation
import Testing
@testable import SiriusXMCore
@testable import SiriusXMNet

@Suite("Request fingerprint")
struct RequestFingerprintTests {
    private static let secret = "SECRETTOKENVALUE"

    private func tuneSource(token: String, path: String = "/playback/play/v1/tuneSource") -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: .post,
            url: RedactingURL(string: "https://api.example.invalid\(path)?consumer=k2&token=\(token)")!,
            headers: [HTTPHeader("Authorization", value: "Bearer \(token)")]
        )
    }

    @Test("the same request always fingerprints the same")
    func fingerprintIsStable() {
        #expect(RequestFingerprint.of(tuneSource(token: "a")) == RequestFingerprint.of(tuneSource(token: "a")))
    }

    @Test("a different token is still the same request")
    func tokenDoesNotChangeTheFingerprint() {
        // This is the invariant that lets a fingerprint be logged at all: it
        // identifies the request, not the credential that varied.
        #expect(RequestFingerprint.of(tuneSource(token: "a")) == RequestFingerprint.of(tuneSource(token: "b")))
    }

    @Test("a different path is a different request")
    func pathChangesTheFingerprint() {
        #expect(
            RequestFingerprint.of(tuneSource(token: "a"))
                != RequestFingerprint.of(tuneSource(token: "a", path: "/playback/play/v1/station"))
        )
    }

    @Test("a different method is a different request")
    func methodChangesTheFingerprint() {
        let get = HTTPRequestSpec(
            method: .get,
            url: RedactingURL(string: "https://api.example.invalid/x?token=\(Self.secret)")!
        )

        #expect(RequestFingerprint.of(get) != RequestFingerprint.of(tuneSource(token: "a")))
    }

    @Test("a different body is a different request")
    func bodyChangesTheFingerprint() {
        let base = HTTPRequestSpec(
            method: .post,
            url: RedactingURL(string: "https://api.example.invalid/x")!
        )
        let withBody = HTTPRequestSpec(
            method: .post,
            url: RedactingURL(string: "https://api.example.invalid/x")!,
            body: Data(#"{"channelId":"sxm:channel-17"}"#.utf8)
        )

        #expect(RequestFingerprint.of(base) != RequestFingerprint.of(withBody))
    }

    @Test("a fingerprint renders as a short opaque slug")
    func fingerprintRendersWithoutTheToken() {
        let rendered = String(describing: RequestFingerprint.of(tuneSource(token: Self.secret)))

        #expect(rendered.hasPrefix("fp:"))
        #expect(rendered.count == 19)
        #expect(!rendered.contains(Self.secret))
        #expect(!rendered.contains("token"))
    }
}

@Suite("Transport redaction")
struct TransportRedactionTests {
    private static let secret = "SECRETTOKENVALUE"

    @Test("a credential header is redacted by name alone")
    func authorizationIsRedactedByName() {
        let header = HTTPHeader("Authorization", value: "Bearer \(Self.secret)")

        #expect(header.isSensitive)
        #expect(header.description == "Authorization: <redacted>")
        #expect(String(reflecting: header).contains(Self.secret) == false)
        #expect(header.resolvedValue == "Bearer \(Self.secret)")
    }

    @Test("cookie headers are redacted by name alone")
    func cookiesAreRedactedByName() {
        for name in ["Cookie", "Set-Cookie", "Proxy-Authorization"] {
            #expect(HTTPHeader(name, value: Self.secret).isSensitive)
        }
    }

    @Test("an app-specific token header has to be marked, and then it is")
    func markedHeadersAreRedacted() {
        let plain = HTTPHeader("X-Trace-Id", value: "abc123")
        let marked = HTTPHeader("X-Siriusxm-Ak-Token", value: Self.secret, sensitivity: .sensitive)

        #expect(!plain.isSensitive)
        #expect(plain.description == "X-Trace-Id: abc123")
        #expect(marked.description == "X-Siriusxm-Ak-Token: <redacted>")
    }

    @Test("a request spec never renders a query or a header value")
    func requestSpecRendersSafely() {
        let request = HTTPRequestSpec(
            method: .post,
            url: RedactingURL(string: "https://api.example.invalid/playback?token=\(Self.secret)")!,
            headers: [HTTPHeader("Authorization", value: "Bearer \(Self.secret)")],
            body: Data(#"{"token":"\#(Self.secret)"}"#.utf8)
        )

        let rendered = String(describing: request)

        #expect(rendered.contains("/playback"))
        #expect(!rendered.contains(Self.secret))
        #expect(!rendered.contains("?token"))
    }

    @Test("a response renders its shape and never its body")
    func responseRendersSafely() {
        let response = HTTPResponsePayload(
            statusCode: 500,
            headers: [HTTPHeader("Set-Cookie", value: "SXMAUTH=\(Self.secret)")],
            body: Data(#"{"error":"\#(Self.secret)"}"#.utf8)
        )

        let rendered = String(describing: response)

        #expect(rendered == "HTTP 500 (24 bytes, json, 1 headers)")
        #expect(!rendered.contains(Self.secret))
    }

    @Test("an empty body is reported as empty, not as opaque")
    func emptyBodyShape() {
        #expect(HTTPResponsePayload(statusCode: 204).bodyShape == "empty")
        #expect(HTTPResponsePayload(statusCode: 200, body: Data("<html>".utf8)).bodyShape == "markup")
        #expect(HTTPResponsePayload(statusCode: 200, body: Data("raw".utf8)).bodyShape == "opaque")
    }

    @Test("Retry-After is read in both forms HTTP defines")
    func retryAfterIsParsed() {
        let seconds = HTTPResponsePayload(statusCode: 429, headers: [HTTPHeader("Retry-After", value: "30")])
        let date = HTTPResponsePayload(
            statusCode: 503,
            headers: [HTTPHeader("Retry-After", value: Date(timeIntervalSinceNow: 120).httpFormatted)]
        )
        let nonsense = HTTPResponsePayload(statusCode: 503, headers: [HTTPHeader("Retry-After", value: "soon")])

        #expect(seconds.retryAfterSeconds == 30)
        #expect(date.retryAfterSeconds == 120)
        #expect(nonsense.retryAfterSeconds == nil)
    }

    @Test("a Retry-After date in the past means retry now, not never")
    func pastRetryAfterIsZero() {
        let payload = HTTPResponsePayload(
            statusCode: 503,
            headers: [HTTPHeader("Retry-After", value: Date(timeIntervalSinceNow: -120).httpFormatted)]
        )

        #expect(payload.retryAfterSeconds == 0)
    }

    @Test("no Retry-After header reads as no instruction")
    func absentRetryAfterIsNil() {
        #expect(HTTPResponsePayload(statusCode: 503).retryAfterSeconds == nil)
    }
}

@Suite("Set-Cookie parsing")
struct SetCookieParserTests {
    @Test("a folded header splits into its cookies")
    func foldedHeaderSplits() {
        let header = "SXMAUTH=value-one; Path=/; HttpOnly, JSESSIONID=value-two; Path=/"
        let fields = SetCookieHeaderParser.fields(fromHeader: header)

        #expect(fields.map(\.name) == ["SXMAUTH", "JSESSIONID"])
        #expect(fields.map(\.resolvedValue) == ["value-one", "value-two"])
    }

    @Test("an Expires comma does not split a cookie")
    func expiresCommaDoesNotSplit() {
        let header = "SXMAUTH=value-one; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/"
        let fields = SetCookieHeaderParser.fields(fromHeader: header)

        #expect(fields.count == 1)
        #expect(fields.first?.name == "SXMAUTH")
        #expect(fields.first?.resolvedValue == "value-one")
    }

    @Test("every cookie value is treated as a credential")
    func cookieValuesAreSensitive() {
        let fields = SetCookieHeaderParser.fields(fromHeader: "SXMAUTH=SECRETVALUE; Path=/")

        #expect(fields.first?.isSensitive == true)
        #expect(fields.first?.description == "SXMAUTH: <redacted>")
        #expect(String(describing: fields).contains("SECRETVALUE") == false)
    }

    @Test("a comma inside a cookie value does not tear it in half")
    func commaInValueIsNotABoundary() {
        // No space after the comma, so this is one cookie with a comma in it.
        let fields = SetCookieHeaderParser.fields(fromHeader: "SXMAUTH=prefix,x=1; Path=/")

        #expect(fields.count == 1)
        #expect(fields.first?.resolvedValue == "prefix,x=1")
    }

    @Test("a field with no equals sign is not a cookie")
    func fieldsWithoutEqualsAreDiscarded() {
        #expect(SetCookieHeaderParser.fields(fromHeader: "HttpOnly").isEmpty)
        #expect(SetCookieHeaderParser.fields(fromHeader: "").isEmpty)
    }
}

extension Date {
    /// RFC 1123, which is the only form `Retry-After` allows for a date.
    var httpFormatted: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: self)
    }
}
