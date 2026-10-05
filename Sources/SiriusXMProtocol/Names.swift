import SiriusXMCore

/// Every SiriusXM name this app knows, in one place.
///
/// This file is the whole argument for the module boundary, so it is worth
/// stating plainly: hostnames, JSON key names, header names, and cookie names
/// appear as string literals **here and nowhere else in the package**. The
/// rest of the code names what it means, not what SiriusXM calls it.
///
/// Each group is an enum with a `name`, rather than a dictionary or a set of
/// constants, so the compiler checks for a typo at the use site and a
/// source-scan test can prove the literals have not escaped this file.
///
/// The wire names themselves are unverified in places. Phase 0.5 confirmed
/// the module API envelope and the `SXMAKTOKEN` / `SXMDATA` shapes from
/// observed traffic; the rest is carried from the public implementations and
/// flagged as provisional. Adding a case here when the real name is
/// discovered is the expected way to correct it.

// MARK: - Hosts

/// A SiriusXM service host.
///
/// A host, never a base `URL`. The only way to get a URL out of one is
/// `base`, which yields a `RedactingURL`, so there is no API on this type that
/// hands out something a caller could log with its query string intact.
public enum SiriusXMHost: Sendable, Hashable, CustomStringConvertible {
    /// The edge gateway. Carries the token-authenticated operations.
    case edgeGateway
    /// The legacy module API host.
    case player
    /// The web player. The only host with a confirmed human sign-in route.
    case webPlayer

    public var name: String {
        switch self {
        case .edgeGateway: return "api.edge-gateway.siriusxm.com"
        case .player: return "player.siriusxm.com"
        case .webPlayer: return "www.siriusxm.com"
        }
    }

    /// `https://<host>`, as a value that cannot render a query.
    public var base: RedactingURL? {
        RedactingURL(string: "https://\(name)")
    }

    /// Stable, safe to log. A hostname is not a secret.
    public var description: String { name }
}

// MARK: - JSON keys

/// A key in a SiriusXM JSON document.
public enum SiriusXMJSONKey: Sendable, Hashable {
    // Module API envelope.
    case moduleListResponse
    case status
    case messages
    case code
    case message

    // Session material.
    case gupID

    // Module request envelope.
    case moduleList
    case modules
    case moduleName
    case moduleRequest
    case resultTemplate
    case standardAuth
    case deviceInfo

    // `deviceInfo` members.
    case appRegion
    case browser
    case browserVersion
    case clientDeviceID
    case clientDeviceType
    case deviceModel
    case osVersion
    case platform
    case player
    case sxmAppVersion

    public var name: String {
        switch self {
        case .moduleListResponse: return "ModuleListResponse"
        case .status: return "status"
        case .messages: return "messages"
        case .code: return "code"
        case .message: return "message"
        case .gupID: return "gupId"
        case .moduleList: return "moduleList"
        case .modules: return "modules"
        case .moduleName: return "moduleName"
        case .moduleRequest: return "moduleRequest"
        case .resultTemplate: return "resultTemplate"
        case .standardAuth: return "standardAuth"
        case .deviceInfo: return "deviceInfo"
        case .appRegion: return "appRegion"
        case .browser: return "browser"
        case .browserVersion: return "browserVersion"
        case .clientDeviceID: return "clientDeviceId"
        case .clientDeviceType: return "clientDeviceType"
        case .deviceModel: return "deviceModel"
        case .osVersion: return "osVersion"
        case .platform: return "platform"
        case .player: return "player"
        case .sxmAppVersion: return "sxmAppVersion"
        }
    }
}

// MARK: - Header names

/// An HTTP header SiriusXM reads or writes.
///
/// `authorization` and `cookie` carry live session material. `SiriusXMNet`
/// redacts them by name without being told, which is why this type exists at
/// all: the transport's redaction list has to name the dangerous headers, and
/// it must do so without importing this module.
public enum SiriusXMHeaderName: Sendable, Hashable {
    case authorization
    case cookie
    case setCookie
    case userAgent
    case accept
    case cacheControl
    case contentType
    case origin
    case referer
    /// The edge gateway's anti-skew clock hint.
    case clock

    public var name: String {
        switch self {
        case .authorization: return "Authorization"
        case .cookie: return "Cookie"
        case .setCookie: return "Set-Cookie"
        case .userAgent: return "User-Agent"
        case .accept: return "Accept"
        case .cacheControl: return "Cache-Control"
        case .contentType: return "Content-Type"
        case .origin: return "Origin"
        case .referer: return "Referer"
        case .clock: return "x-sxm-clock"
        }
    }
}

// MARK: - Cookie names

/// A cookie SiriusXM sets during sign-in.
public enum SiriusXMCookieName: Sendable, Hashable, CaseIterable {
    /// Proof of authentication.
    case auth
    /// The access token. Carries the payload the edge gateway wants.
    case akToken
    /// Percent-encoded JSON carrying `gupId` and account metadata.
    case data
    case sessionID

    public var name: String {
        switch self {
        case .auth: return "SXMAUTH"
        case .akToken: return "SXMAKTOKEN"
        case .data: return "SXMDATA"
        case .sessionID: return "JSESSIONID"
        }
    }

    /// Cookies whose value is live session material.
    ///
    /// `SXMAUTH` and `SXMAKTOKEN` are enough to act as the subscriber. `SXMDATA`
    /// identifies the account, so it is in the set too.
    public static let sessionBearing: Set<SiriusXMCookieName> = [.auth, .akToken, .data]
}

// MARK: - Message codes

/// A `messages[].code` from the module API.
///
/// An enum with an associated payload rather than a raw-value enum, so an
/// unrecognised code is carried and reported instead of being dropped by a
/// failable initialiser. The codes are unverified against SiriusXM; they are
/// carried from observed and public traffic.
public enum ModuleMessageCode: Sendable, Hashable, CustomStringConvertible {
    /// Request accepted.
    case success
    /// Wrong or absent credentials. Observed live, undocumented.
    case badCredentials
    /// Authentication required, or the session expired and must be rebuilt.
    case authenticationRequired
    /// Session expired.
    case sessionExpired
    /// Anything not yet seen. Carried through verbatim.
    case unrecognized(Int)

    public static func classify(_ code: Int) -> ModuleMessageCode {
        switch code {
        case 100: return .success
        case 101: return .badCredentials
        case 201: return .authenticationRequired
        case 208: return .sessionExpired
        default: return .unrecognized(code)
        }
    }

    public var rawCode: Int {
        switch self {
        case .success: return 100
        case .badCredentials: return 101
        case .authenticationRequired: return 201
        case .sessionExpired: return 208
        case .unrecognized(let value): return value
        }
    }

    public var isSuccess: Bool { self == .success }

    /// Never confuse "credentials were wrong" with "the session is gone".
    /// They mean retry differently, and only one of them is recoverable
    /// without the subscriber.
    public var isCredentialFailure: Bool { self == .badCredentials }

    public var isSessionExpired: Bool {
        self == .authenticationRequired || self == .sessionExpired
    }

    public var description: String { String(rawCode) }
}
