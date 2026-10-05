import Foundation
import SiriusXMCore
import SiriusXMNet

/// `ModuleListResponse.status`.
///
/// The whole authentication decision on this API hangs off this one integer.
/// `1` is authenticated and nothing else is. A value the app has never seen
/// is carried rather than guessed at, because guessing wrong here means
/// treating a failed sign-in as a successful one.
public enum ModuleListStatus: Sendable, Hashable {
    case authenticated
    case notAuthenticated
    case unrecognized(Int)

    public var isAuthenticated: Bool { self == .authenticated }

    /// A token for display in probe output. Not the raw status: the point is
    /// to distinguish "not 1" from "some other number", which a bare integer
    /// does not.
    public var displayToken: String {
        switch self {
        case .authenticated: return "1"
        case .notAuthenticated: return "not-1"
        case .unrecognized(let value): return "unexpected(\(value))"
        }
    }
}

/// One `messages[]` entry.
public struct ModuleMessage: Sendable, Hashable {
    public let code: Int
    public let text: String

    public var classification: ModuleMessageCode { ModuleMessageCode.classify(code) }
}

/// A parsed module API envelope.
public struct ModuleListResponse: Sendable, Hashable {
    public let status: ModuleListStatus
    public let messages: [ModuleMessage]

    public var primaryCode: ModuleMessageCode? { messages.first?.classification }

    public var hasExpired: Bool { messages.contains { $0.classification.isSessionExpired } }
    public var hasCredentialFailure: Bool { messages.contains { $0.classification.isCredentialFailure } }
}

public enum ModuleAPIParserError: Error, Sendable, Hashable, CustomStringConvertible {
    case notJSON
    case missingModuleListResponse

    public var description: String {
        switch self {
        case .notJSON: return "response-body-not-json"
        case .missingModuleListResponse: return "no-ModuleListResponse-object"
        }
    }
}

/// Pure parsing of the legacy `player.siriusxm.com` module API.
///
/// Everything here is offline and deterministic. The credential-gated steps
/// are the only part of Phase 0.5 that can fail for reasons outside this
/// app's control, so all the interpretation of a response lives in a layer the
/// test suite can pin down without a network.
///
/// No password ever reaches this type. It reads responses and cookies; it
/// does not build credentials, and there is no method here that accepts one.
public enum ModuleAPIParser {
    // MARK: - Response envelope

    public static func parse(_ text: String) throws -> ModuleListResponse {
        guard let data = text.data(using: .utf8) else { throw ModuleAPIParserError.notJSON }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ModuleListResponse {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ModuleAPIParserError.notJSON
        }

        guard let top = root as? [String: Any],
              let payload = top[SiriusXMJSONKey.moduleListResponse.name] as? [String: Any]
        else {
            throw ModuleAPIParserError.missingModuleListResponse
        }

        return ModuleListResponse(
            status: parseStatus(payload[SiriusXMJSONKey.status.name]),
            messages: parseMessages(payload[SiriusXMJSONKey.messages.name])
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
            let code = (object[SiriusXMJSONKey.code.name] as? NSNumber)?.intValue ?? -1
            let text = object[SiriusXMJSONKey.message.name] as? String ?? ""
            return ModuleMessage(code: code, text: text)
        }
    }

    // MARK: - Cookies

    /// The access token out of a `Set-Cookie` set.
    public static func extractAKToken(fromCookies cookies: [HTTPCookieField]) -> String? {
        guard let raw = cookies.first(where: { $0.name == SiriusXMCookieName.akToken.name })?.value else {
            return nil
        }
        return parseAKToken(raw)
    }

    /// `SXMAKTOKEN` arrives as `…=<token>,…`: an opaque wrapper around the
    /// token, delimited by `=` on the left and `,` on the right. The wrapper
    /// is not stable, so the token is taken positionally.
    public static func parseAKToken(_ raw: String) -> String? {
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

    /// The account identifier out of a `Set-Cookie` set.
    public static func extractGupID(fromCookies cookies: [HTTPCookieField]) -> String? {
        guard let raw = cookies.first(where: { $0.name == SiriusXMCookieName.data.name })?.value else {
            return nil
        }
        return parseGupID(raw)
    }

    /// `SXMDATA` is a percent-encoded JSON object with `gupId` at the top
    /// level. Some responses double-encode it, so decoding is retried.
    public static func parseGupID(_ raw: String) -> String? {
        let decoded = percentDecoded(raw)
        guard let data = decoded.data(using: .utf8) else { return nil }

        let root = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let object = root as? [String: Any],
              let gupID = object[SiriusXMJSONKey.gupID.name] as? String,
              !gupID.isEmpty
        else {
            return nil
        }
        return gupID
    }

    /// Percent-decoding is repeated until it stops changing, capped so a
    /// pathological value cannot spin.
    public static func percentDecoded(_ raw: String) -> String {
        var current = raw
        for _ in 0..<3 {
            guard let decoded = current.removingPercentEncoding, decoded != current else {
                return current
            }
            current = decoded
        }
        return current
    }

    /// Names and presence only, never values. Safe to print.
    public static func describeCookiePresence(_ cookies: [HTTPCookieField]) -> String {
        let known = SiriusXMCookieName.allCases.map(\.name)
        let present = known.filter { name in cookies.contains { $0.name == name } }
        let other = cookies.filter { cookie in !known.contains(cookie.name) }.map(\.name).sorted()
        let listed = (present + other).joined(separator: ",")
        return listed.isEmpty ? "none" : listed
    }
}
