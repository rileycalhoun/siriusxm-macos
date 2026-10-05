import Foundation

/// A `messages[].code` from a module-API response.
///
/// Modelled as an enum with an associated payload rather than a raw-value
/// enum so that an unrecognised code can be carried and reported instead of
/// being silently dropped by a failable initialiser.
enum ModuleMessageCode: Sendable, Equatable, CustomStringConvertible {
    /// Request accepted.
    case success
    /// Wrong or absent username/password. Observed live, undocumented.
    case badCredentials
    /// Authentication required, or the session expired and must be rebuilt.
    case authenticationRequired
    /// Session expired.
    case sessionExpired
    /// Anything the probe has not seen. Carried through verbatim.
    case unrecognized(Int)

    static func classify(_ code: Int) -> ModuleMessageCode {
        switch code {
        case 100: return .success
        case 101: return .badCredentials
        case 201: return .authenticationRequired
        case 208: return .sessionExpired
        default: return .unrecognized(code)
        }
    }

    var rawCode: Int {
        switch self {
        case .success: return 100
        case .badCredentials: return 101
        case .authenticationRequired: return 201
        case .sessionExpired: return 208
        case .unrecognized(let value): return value
        }
    }

    var isSuccess: Bool { self == .success }

    /// The probe must never confuse "credentials were wrong" with "the
    /// session is gone"; both mean retry differently.
    var isCredentialFailure: Bool { self == .badCredentials }

    var isSessionExpired: Bool {
        self == .authenticationRequired || self == .sessionExpired
    }

    var description: String { String(rawCode) }
}

/// `ModuleListResponse.status`.
///
/// The whole authentication decision on this API hangs off this one integer.
/// `1` is authenticated, anything else is not.
enum ModuleListStatus: Sendable, Equatable {
    case authenticated
    case notAuthenticated
    case unrecognized(Int)

    var isAuthenticated: Bool { self == .authenticated }

    var displayToken: String {
        switch self {
        case .authenticated: return "1"
        case .notAuthenticated: return "not-1"
        case .unrecognized(let value): return "unexpected(\(value))"
        }
    }
}

struct ModuleMessage: Sendable, Equatable {
    let code: Int
    let text: String

    var classification: ModuleMessageCode { ModuleMessageCode.classify(code) }
}

struct ModuleListResponse: Sendable, Equatable {
    let status: ModuleListStatus
    let messages: [ModuleMessage]

    var primaryCode: ModuleMessageCode? { messages.first?.classification }

    var hasExpired: Bool { messages.contains { $0.classification.isSessionExpired } }
    var hasCredentialFailure: Bool { messages.contains { $0.classification.isCredentialFailure } }
}

enum ModuleAPIParserError: Error, Sendable, Equatable, CustomStringConvertible {
    case notJSON
    case missingModuleListResponse

    var description: String {
        switch self {
        case .notJSON: return "response-body-not-json"
        case .missingModuleListResponse: return "no-ModuleListResponse-object"
        }
    }
}

/// Pure parsing of the legacy `player.siriusxm.com` module API.
///
/// Everything here is offline and deterministic. That is the point: the
/// credential-gated steps of the probe are the only part of Phase 0.5 that
/// can fail for reasons outside our control, so all the interpretation of a
/// response lives in a layer the test suite can pin down without a network.
enum ModuleAPIParser {
    static let authCookieName = "SXMAUTH"
    static let akTokenCookieName = "SXMAKTOKEN"
    static let dataCookieName = "SXMDATA"
    static let sessionCookieName = "JSESSIONID"

    // MARK: - Response envelope

    static func parse(_ text: String) throws -> ModuleListResponse {
        guard let data = text.data(using: .utf8) else { throw ModuleAPIParserError.notJSON }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ModuleListResponse {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ModuleAPIParserError.notJSON
        }

        guard let top = root as? [String: Any],
              let payload = top["ModuleListResponse"] as? [String: Any] else {
            throw ModuleAPIParserError.missingModuleListResponse
        }

        return ModuleListResponse(
            status: parseStatus(payload["status"]),
            messages: parseMessages(payload["messages"])
        )
    }

    private static func parseStatus(_ raw: Any?) -> ModuleListStatus {
        guard let number = raw as? NSNumber else { return .unrecognized(-1) }
        let value = number.intValue
        switch value {
        case 1: return .authenticated
        case 0: return .notAuthenticated
        default: return .unrecognized(value)
        }
    }

    private static func parseMessages(_ raw: Any?) -> [ModuleMessage] {
        guard let entries = raw as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let object = entry as? [String: Any] else { return nil }
            let code = (object["code"] as? NSNumber)?.intValue ?? -1
            let text = object["message"] as? String ?? ""
            return ModuleMessage(code: code, text: text)
        }
    }

    // MARK: - Cookies

    static func extractAKToken(fromCookies cookies: [HTTPCookieField]) -> String? {
        guard let raw = cookies.first(where: { $0.name == akTokenCookieName })?.value else {
            return nil
        }
        return parseAKToken(raw)
    }

    /// `SXMAKTOKEN` arrives as `…=<token>,…`: an opaque wrapper around the
    /// token delimited by `=` on the left and `,` on the right. The wrapper
    /// is not stable, so the token is taken positionally.
    static func parseAKToken(_ raw: String) -> String? {
        let afterEquals = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard afterEquals.count == 2 else { return nil }

        let tail = afterEquals[1]
        // Empty subsequences must be kept: an empty token before the comma is
        // a malformed cookie, and dropping the empty piece would silently
        // promote the *trailing* noise segment to be the token.
        let pieces = tail.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let candidate = pieces.first else { return nil }

        let token = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : String(token)
    }

    static func extractGupID(fromCookies cookies: [HTTPCookieField]) -> String? {
        guard let raw = cookies.first(where: { $0.name == dataCookieName })?.value else {
            return nil
        }
        return parseGupID(raw)
    }

    /// `SXMDATA` is a percent-encoded JSON object; `gupId` lives at the top
    /// level. Some responses double-encode it, so decoding is retried.
    static func parseGupID(_ raw: String) -> String? {
        let decoded = percentDecoded(raw)
        guard let data = decoded.data(using: .utf8) else { return nil }

        let root = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let object = root as? [String: Any],
              let gupID = object["gupId"] as? String,
              !gupID.isEmpty else {
            return nil
        }
        return gupID
    }

    static func percentDecoded(_ raw: String) -> String {
        var current = raw
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else {
                return current
            }
            current = decoded
        }
        return current
    }

    /// Summary of a cookie set that is safe to print: names and presence
    /// only, never values.
    static func describeCookiePresence(_ cookies: [HTTPCookieField]) -> String {
        let known = [authCookieName, akTokenCookieName, dataCookieName, sessionCookieName]
        let present = known.filter { name in cookies.contains { $0.name == name } }
        let other = cookies.filter { cookie in !known.contains(cookie.name) }.map(\.name).sorted()
        let listed = (present + other).joined(separator: ",")
        return listed.isEmpty ? "none" : listed
    }
}