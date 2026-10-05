import SiriusXMCore

/// One addressable SiriusXM endpoint: a host, a path, and an optional query.
///
/// The type is deliberately unable to produce a bare `URL`. Its only route to
/// an address is `redactedURL()`, which yields a `RedactingURL`, so a path
/// that later gains a query string carrying a token cannot start leaking into
/// a log line through a convenient `URL` return type.
public struct SiriusXMEndpoint: Sendable, Hashable {
    public let host: SiriusXMHost
    public let path: String

    /// Pre-encoded query text, without the leading `?`.
    ///
    /// A string rather than a dictionary because the one query in use is
    /// SiriusXM's own literal, and dictionary encoding would invent an order
    /// the server does not promise to accept.
    public let query: String?

    public init(host: SiriusXMHost, path: String, query: String? = nil) {
        self.host = host
        self.path = path
        self.query = query
    }

    /// The address, redacted. `nil` only if a path cannot form a URL, which
    /// for these constants would be a bug rather than a runtime condition.
    public func redactedURL() -> RedactingURL? {
        var text = "https://\(host.name)\(path)"
        if let query { text += "?\(query)" }
        return RedactingURL(string: text)
    }

    /// Host and path with no query, for logs and for equality on identity.
    public var displayTarget: String { "\(host.name)\(path)" }
}

/// The module API operations this app knows by name.
///
/// `authentication` is named but deliberately not wired to anything. Phase 0.5
/// found no evidence that it still works, and building a caller for it now is
/// the lock-in this phase exists to prevent. The case exists so that a future
/// phase either proves the operation or deletes it, rather than rediscovering
/// it from a string in a comment.
public enum SiriusXMModuleOperation: Sendable, Hashable {
    case authentication
    case resume

    public var name: String {
        switch self {
        case .authentication: return "modify/authentication"
        case .resume: return "resume"
        }
    }
}

/// Every endpoint this app addresses.
///
/// Paths come from two independent sources that agree: the module API shape,
/// stable in the public implementations since 2015, and the edge gateway's
/// operation list. Nothing here is invented, and nothing here is confirmed to
/// still be reachable. That distinction is carried in `docs/` rather than
/// hidden, because a Phase 0 that overstates its evidence is worse than one
/// that admits what it does not know.
public enum SiriusXMEndpoints {
    /// `GET /profile/v4/profiles/me` on the edge gateway.
    public static let profileMe = SiriusXMEndpoint(host: .edgeGateway, path: "/profile/v4/profiles/me")

    /// `GET /subscription/v1/subscriptions` on the edge gateway.
    public static let subscriptions = SiriusXMEndpoint(host: .edgeGateway, path: "/subscription/v1/subscriptions")

    /// `POST /session/v1/sessions/refresh` on the edge gateway.
    ///
    /// Named for what it is meant to do. Phase 0.5 did not confirm it exists,
    /// and `BoundedSessionRefresher` currently renews through the credential
    /// provider instead.
    public static let sessionRefresh = SiriusXMEndpoint(host: .edgeGateway, path: "/session/v1/sessions/refresh")

    /// The web player. The only confirmed route to a human sign-in.
    public static let browserEntry = SiriusXMEndpoint(host: .webPlayer, path: "/player")

    /// A module API call.
    public static func module(
        _ operation: SiriusXMModuleOperation,
        trial: Bool = false
    ) -> SiriusXMEndpoint {
        SiriusXMEndpoint(
            host: .player,
            path: "/rest/v2/experience/modules/\(operation.name)",
            query: trial ? "OAtrial=false" : nil
        )
    }
}

/// The client identity sent with every request.
///
/// Stable and self-describing on purpose. These values never change between
/// runs and are never randomised. The app does not impersonate a browser: a
/// request that fails because of an honest client identity is a finding to
/// report, not a problem to hide behind a spoofed fingerprint.
public enum SiriusXMClientIdentity {
    public static let userAgent = "SiriusXMApp/0.1 phase-0-scaffolding"
    public static let appVersion = "0.1.0"
    public static let browserName = "URLSession"
    public static let browserVersion = "sxm-0.1"
    public static let osVersion = "macOS"

    /// The `deviceInfo` object as the module API expects it.
    ///
    /// `clientDeviceId` is the literal string `"null"`. This app mints no
    /// device identifier, rotates nothing, and varies nothing between runs.
    /// Device-limit circumvention is not a feature here; sending an honest
    /// unknown is.
    public static func deviceInfo() -> [String: String] {
        [
            SiriusXMJSONKey.appRegion.name: "US",
            SiriusXMJSONKey.browser.name: browserName,
            SiriusXMJSONKey.browserVersion.name: browserVersion,
            SiriusXMJSONKey.clientDeviceID.name: "null",
            SiriusXMJSONKey.clientDeviceType.name: "web",
            SiriusXMJSONKey.deviceModel.name: "K2WebClient",
            SiriusXMJSONKey.osVersion.name: osVersion,
            SiriusXMJSONKey.platform.name: "Web",
            SiriusXMJSONKey.player.name: "html5",
            SiriusXMJSONKey.sxmAppVersion.name: appVersion
        ]
    }

    /// The module request envelope.
    ///
    /// `standardAuth` is left out when absent rather than sent null, because
    /// the two are not the same on this API and only one of them has been
    /// observed.
    public static func moduleBody(
        resultTemplate: String,
        standardAuth: [String: String]?
    ) -> [String: Any] {
        var moduleRequest: [String: Any] = [
            SiriusXMJSONKey.resultTemplate.name: resultTemplate,
            SiriusXMJSONKey.deviceInfo.name: deviceInfo()
        ]
        if let standardAuth {
            moduleRequest[SiriusXMJSONKey.standardAuth.name] = standardAuth
        }

        return [
            SiriusXMJSONKey.moduleList.name: [
                SiriusXMJSONKey.modules.name: [
                    [
                        SiriusXMJSONKey.moduleName.name: resultTemplate,
                        SiriusXMJSONKey.moduleRequest.name: moduleRequest
                    ]
                ]
            ]
        ]
    }
}
