import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Redaction

/// Makes a string safe to print in a report row.
///
/// Three passes, in this order:
///   1. newlines and pipes are flattened so a note can never break the
///      `path | result | statusCode | acquired | notes` column layout;
///   2. anything from a `?` onwards is dropped, because a query string is
///      where media and token parameters live;
///   3. any whitespace-delimited run of 24 or more characters drawn from the
///      base64url alphabet is collapsed to `<redacted>`, which catches a token
///      or cookie value that ended up in a note through some other route.
enum Redactor {
    static let replacement = "<redacted>"
    static let longRunThreshold = 24

    static func sanitize(_ text: String) -> String {
        var working = text.replacingOccurrences(of: "\n", with: " ")
        working = working.replacingOccurrences(of: "\r", with: " ")
        working = working.replacingOccurrences(of: "|", with: "/")
        working = stripQueryStrings(in: working)
        working = collapseLongRuns(in: working)

        while working.contains("  ") {
            working = working.replacingOccurrences(of: "  ", with: " ")
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripQueryStrings(in text: String) -> String {
        var pieces: [String] = []
        for token in text.split(separator: " ", omittingEmptySubsequences: true) {
            var piece = String(token)
            if let mark = piece.firstIndex(of: "?") {
                piece = String(piece[piece.startIndex..<mark]) + "?" + replacement
            }
            pieces.append(piece)
        }
        return pieces.joined(separator: " ")
    }

    private static func collapseLongRuns(in text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .map { token -> String in
                guard token.count >= longRunThreshold, isTokenAlphabet(String(token)) else {
                    return String(token)
                }
                return replacement
            }
            .joined(separator: " ")
    }

    private static func isTokenAlphabet(_ candidate: String) -> Bool {
        candidate.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+"
                || character == "/" || character == "=" || character == "_"
                || character == "-"
        }
    }
}

// MARK: - Report

/// The outcome of one candidate acquisition path.
enum ProbeResult: Sendable {
    /// The request completed; HTTP status says nothing about credentials.
    case observed(statusCode: Int)
    /// A usable token or cookie set was obtained.
    case acquiredSession
    /// The request completed and the server refused the credentials.
    case rejected(statusCode: Int?, detail: String)
    /// Cannot be attempted at all from this harness.
    case blocked(detail: String)
    /// A path that exists and is known, but needs a human at a keyboard.
    case documented(detail: String)
    /// Needs `SXM_USERNAME` and `SXM_PASSWORD`, which were not supplied.
    case skippedNoCredential(detail: String)
    /// No HTTP response arrived.
    case transportFailure(detail: String)

    var label: String {
        switch self {
        case .observed: return "observed"
        case .acquiredSession: return "acquired"
        case .rejected: return "rejected"
        case .blocked: return "blocked"
        case .documented: return "documented"
        case .skippedNoCredential: return "skipped-no-credential"
        case .transportFailure: return "transport-failure"
        }
    }

    var statusCode: Int? {
        switch self {
        case .observed(let code): return code
        case .rejected(let code, _): return code
        case .acquiredSession, .blocked, .documented, .skippedNoCredential, .transportFailure: return nil
        }
    }

    var detail: String {
        switch self {
        case .observed, .acquiredSession: return ""
        case .rejected(_, let detail): return detail
        case .blocked(let detail): return detail
        case .documented(let detail): return detail
        case .skippedNoCredential(let detail): return detail
        case .transportFailure(let detail): return detail
        }
    }

    var acquired: Bool {
        if case .acquiredSession = self { return true }
        return false
    }

    var statusColumn: String {
        statusCode.map { String($0) } ?? "-"
    }
}

/// One machine-readable row.
struct ProbeReport: Sendable {
    let path: String
    let result: ProbeResult
    let notes: String

    init(path: String, result: ProbeResult, notes: String) {
        self.path = path
        self.result = result
        self.notes = notes
    }

    /// `path | result | statusCode | acquired(bool) | notes`
    ///
    /// The merged note is sanitized at render time rather than at
    /// construction, so a detail string baked into `ProbeResult` is covered
    /// by exactly the same rules as a free-text note.
    var line: String {
        let merged: String
        if result.detail.isEmpty {
            merged = notes
        } else if notes.isEmpty {
            merged = result.detail
        } else {
            merged = "\(notes); \(result.detail)"
        }

        let acquired = result.acquired ? "true" : "false"
        return "\(path) | \(result.label) | \(result.statusColumn) | \(acquired) | \(Redactor.sanitize(merged))"
    }
}

// MARK: - Clock

/// Supplies the monotonic `x-sxm-clock` counter the edge gateway expects.
///
/// Reference material shows the header as `[0,<counter>]` with the counter
/// increasing across the life of a session. The probe issues a small, fixed
/// number of requests, so a plain monotonic integer is enough. It is a
/// class rather than a struct so the counter survives `await` boundaries
/// without an `inout` parameter.
final class ProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "[0,\(counter)]"
    }
}

// MARK: - Endpoints and request construction

/// The hosts, paths, and request bodies under test.
///
/// Hosts and paths come from two independent places that agree: the legacy
/// module API shape, which has been stable in the public implementations
/// since 2015, and the edge-gateway operation list in the reference
/// implementation. Nothing here is invented.
enum ProbeEndpoint {
    static let edgeGatewayHost = "api.edge-gateway.siriusxm.com"
    static let playerHost = "player.siriusxm.com"
    static let webPlayerHost = "www.siriusxm.com"

    static let profileMePath = "/profile/v4/profiles/me"
    static let subscriptionsPath = "/subscription/v1/subscriptions"
    static let sessionRefreshPath = "/session/v1/sessions/refresh"

    static let modulePrefix = "/rest/v2/experience/modules/"
    static let authenticationOperation = "modify/authentication"
    static let resumeOperation = "resume"
    static let resumeQuery = "OAtrial=false"

    static let browserEntryPath = "/player"

    /// Stable, self-describing client identity.
    ///
    /// These values never change between runs and are never randomised. The
    /// probe deliberately does not impersonate a browser: a false negative
    /// caused by an honest client identity is a finding to report, not a
    /// problem to hide behind a spoofed fingerprint.
    static let userAgent = "SiriusXMProbe/0.5 auth-feasibility-spike"
    static let appVersion = "0.5.0"
    static let browserName = "URLSession"
    static let browserVersion = "probe-0.5"
    static let osVersion = "macOS"

    /// `deviceInfo` as the module API expects it.
    ///
    /// `clientDeviceId` is the literal string `"null"`, matching what the
    /// public implementations send. This probe mints no device identifier,
    /// rotates nothing, and varies nothing between runs.
    static func deviceInfo() -> [String: String] {
        [
            "appRegion": "US",
            "browser": browserName,
            "browserVersion": browserVersion,
            "clientDeviceId": "null",
            "clientDeviceType": "web",
            "deviceModel": "K2WebClient",
            "osVersion": osVersion,
            "platform": "Web",
            "player": "html5",
            "sxmAppVersion": appVersion
        ]
    }

    static func moduleBody(standardAuth: [String: String]?, resultTemplate: String = "login") -> [String: Any] {
        var moduleRequest: [String: Any] = [
            "resultTemplate": resultTemplate,
            "deviceInfo": deviceInfo()
        ]
        if let standardAuth {
            moduleRequest["standardAuth"] = standardAuth
        }

        return [
            "moduleList": [
                "modules": [
                    [
                        "moduleName": resultTemplate,
                        "moduleRequest": moduleRequest
                    ]
                ]
            ]
        ]
    }

    static func edgeURL(_ path: String) -> URL? {
        URL(string: "https://\(edgeGatewayHost)\(path)")
    }

    static func moduleURL(_ operation: String, query: String? = nil) -> URL? {
        var text = "https://\(playerHost)\(modulePrefix)\(operation)"
        if let query { text += "?\(query)" }
        return URL(string: text)
    }

    static func browserEntryURL() -> URL? {
        URL(string: "https://\(webPlayerHost)\(browserEntryPath)")
    }

    static func makeEdgeRequest(
        method: String,
        path: String,
        bearerToken: String?,
        body: [String: Any]?,
        clock: String?
    ) -> URLRequest? {
        guard let url = edgeURL(path) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        applyCommonHeaders(to: &request, bearerToken: bearerToken)

        if let clock {
            request.setValue(clock, forHTTPHeaderField: "x-sxm-clock")
        }

        if let body {
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                return nil
            }
            request.httpBody = data
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }

        return request
    }

    static func makeModuleRequest(
        operation: String,
        query: String? = nil,
        body: [String: Any],
        bearerToken: String? = nil,
        cookieHeader: String? = nil
    ) -> URLRequest? {
        guard let url = moduleURL(operation, query: query),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        applyCommonHeaders(to: &request, bearerToken: bearerToken)
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://\(playerHost)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(playerHost)/", forHTTPHeaderField: "Referer")

        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        return request
    }

    static func makeCookieHeader(from cookies: [HTTPCookieField]) -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func applyCommonHeaders(to request: inout URLRequest, bearerToken: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
    }
}

// MARK: - Probe driver

/// Walks every candidate credential-acquisition path and records what
/// happened to each one.
///
/// Requests are issued exactly once. There are no retries anywhere in this
/// file: a bounded, fingerprint-stable single shot is the only safe policy
/// against an endpoint that may rate-limit or lock a subscriber account.
enum SessionShapeProbe {
    static func run(
        credential: AccountCredential?,
        client: EphemeralHTTPClient = .shared
    ) async -> [ProbeReport] {
        let clock = ProbeClock()
        var reports: [ProbeReport] = []

        // Group A — edge gateway, no credentials. Establishes that the
        // documented operations exist and that they refuse anonymous calls.
        reports.append(
            await observeShape(
                client: client,
                path: "edge-shape-profile-me",
                request: ProbeEndpoint.makeEdgeRequest(
                    method: "GET",
                    path: ProbeEndpoint.profileMePath,
                    bearerToken: nil,
                    body: nil,
                    clock: nil
                ),
                note: "GET profile v4 me, no authorization header",
                parseModule: false
            )
        )

        reports.append(
            await observeShape(
                client: client,
                path: "edge-shape-subscriptions",
                request: ProbeEndpoint.makeEdgeRequest(
                    method: "GET",
                    path: ProbeEndpoint.subscriptionsPath,
                    bearerToken: nil,
                    body: nil,
                    clock: nil
                ),
                note: "GET subscription v1 subscriptions, no authorization header",
                parseModule: false
            )
        )

        reports.append(
            await observeShape(
                client: client,
                path: "edge-shape-session-refresh",
                request: ProbeEndpoint.makeEdgeRequest(
                    method: "POST",
                    path: ProbeEndpoint.sessionRefreshPath,
                    bearerToken: nil,
                    body: ["location": NSNull()],
                    clock: clock.next()
                ),
                note: "POST session v1 sessions refresh, location null, no refresh cookie",
                parseModule: false
            )
        )

        // Group B — legacy module API, no credentials. Establishes that the
        // module API is still served and how it reports missing credentials.
        reports.append(
            await observeShape(
                client: client,
                path: "module-shape-auth-unauthenticated",
                request: ProbeEndpoint.makeModuleRequest(
                    operation: ProbeEndpoint.authenticationOperation,
                    body: ProbeEndpoint.moduleBody(standardAuth: nil)
                ),
                note: "POST modify authentication, deviceInfo only, no standardAuth",
                parseModule: true
            )
        )

        reports.append(
            await observeShape(
                client: client,
                path: "module-shape-resume-unauthenticated",
                request: ProbeEndpoint.makeModuleRequest(
                    operation: ProbeEndpoint.resumeOperation,
                    query: ProbeEndpoint.resumeQuery,
                    body: ProbeEndpoint.moduleBody(standardAuth: nil, resultTemplate: "resume")
                ),
                note: "POST resume with OAtrial false, no session cookies",
                parseModule: true
            )
        )

        // Group C — paths that need the operator's own account.
        reports.append(contentsOf: await runCredentialGatedGroup(client: client, credential: credential, clock: clock))

        // Group D — paths this harness will not attempt.
        reports.append(
            ProbeReport(
                path: "edge-session-refresh-grant",
                result: .blocked(detail: "refresh requires an existing sxm-refresh-token cookie issued by an interactive sign-in; this harness will not mint one"),
                notes: "endpoint exists and refuses anonymous calls"
            )
        )

        reports.append(
            ProbeReport(
                path: "web-auth-token-cookie",
                result: .documented(detail: "requires a human-operated sign-in; the resulting first-party AUTH_TOKEN cookie carries the edge-gateway access token"),
                notes: "browser entry point is a plain path on \(ProbeEndpoint.webPlayerHost), no query string"
            )
        )

        return reports
    }

    // MARK: Group A and B

    private static func observeShape(
        client: EphemeralHTTPClient,
        path: String,
        request: URLRequest?,
        note: String,
        parseModule: Bool
    ) async -> ProbeReport {
        guard let request else {
            return ProbeReport(path: path, result: .blocked(detail: "request-construction-failed"), notes: note)
        }

        let result = await client.send(request)
        var notes = "\(note); body=\(result.bodyShape); cookies=\(result.cookies.count)"

        if parseModule, let parsed = try? ModuleAPIParser.parse(result.body) {
            notes += "; moduleStatus=\(parsed.status.displayToken)"
            if let code = parsed.primaryCode {
                notes += "; messageCode=\(code.rawCode)"
            }
        }

        if let failure = result.transportFailure {
            return ProbeReport(path: path, result: .transportFailure(detail: failure.description), notes: notes)
        }

        return ProbeReport(path: path, result: .observed(statusCode: result.statusCode), notes: notes)
    }

    // MARK: Group C

    private static func runCredentialGatedGroup(
        client: EphemeralHTTPClient,
        credential: AccountCredential?,
        clock: ProbeClock
    ) async -> [ProbeReport] {
        guard let credential else {
            let detail = "requires \(CredentialPrompt.requiredVariableNames.joined(separator: " and ")) in the environment"
            return [
                ProbeReport(path: "module-auth-programmatic", result: .skippedNoCredential(detail: detail), notes: "legacy module API sign-in"),
                ProbeReport(path: "module-resume-programmatic", result: .skippedNoCredential(detail: detail), notes: "replays the cookie set from module-auth-programmatic"),
                ProbeReport(path: "module-token-on-edge-gateway", result: .skippedNoCredential(detail: detail), notes: "presents the legacy AK token as an edge-gateway bearer")
            ]
        }

        var reports: [ProbeReport] = []

        // C1 — programmatic sign-in against the legacy module API.
        var body = ProbeEndpoint.moduleBody(standardAuth: nil)
        credential.withStandardAuth { username, password in
            body = ProbeEndpoint.moduleBody(
                standardAuth: ["username": username, "password": password]
            )
        }

        let authPath = "module-auth-programmatic"
        let authNote = "POST modify authentication with standardAuth from environment"

        guard let authRequest = ProbeEndpoint.makeModuleRequest(
            operation: ProbeEndpoint.authenticationOperation,
            body: body
        ) else {
            reports.append(ProbeReport(path: authPath, result: .blocked(detail: "request-construction-failed"), notes: authNote))
            reports.append(ProbeReport(path: "module-resume-programmatic", result: .blocked(detail: "prerequisite-failed"), notes: ""))
            reports.append(ProbeReport(path: "module-token-on-edge-gateway", result: .blocked(detail: "prerequisite-failed"), notes: ""))
            return reports
        }

        let authResult = await client.send(authRequest)

        guard authResult.transportFailure == nil else {
            let failure = authResult.transportFailure?.description ?? "unknown"
            reports.append(ProbeReport(path: authPath, result: .transportFailure(detail: failure), notes: authNote))
            reports.append(ProbeReport(path: "module-resume-programmatic", result: .blocked(detail: "prerequisite-failed"), notes: ""))
            reports.append(ProbeReport(path: "module-token-on-edge-gateway", result: .blocked(detail: "prerequisite-failed"), notes: ""))
            return reports
        }

        let authCookies = authResult.cookies
        let akToken = ModuleAPIParser.extractAKToken(fromCookies: authCookies)
        let gupID = ModuleAPIParser.extractGupID(fromCookies: authCookies)
        let hasAuthCookie = authCookies.contains { $0.name == ModuleAPIParser.authCookieName }

        var authNotes = "\(authNote); http=\(authResult.statusCode); body=\(authResult.bodyShape)"
        authNotes += "; cookieNames=\(ModuleAPIParser.describeCookiePresence(authCookies))"
        authNotes += "; sxmauth=\(hasAuthCookie ? "present" : "absent")"
        authNotes += "; akToken=\(akToken == nil ? "absent" : "present")"
        authNotes += "; gupId=\(gupID == nil ? "absent" : "present")"

        let parsed = try? ModuleAPIParser.parse(authResult.body)
        if let parsed {
            authNotes += "; moduleStatus=\(parsed.status.displayToken)"
            if let code = parsed.primaryCode {
                authNotes += "; messageCode=\(code.rawCode)"
            }
        }

        var material: SessionMaterial?
        if parsed?.status.isAuthenticated == true, hasAuthCookie {
            let built = SessionMaterial(
                token: akToken,
                gupID: gupID,
                cookieNames: authCookies.map(\.name).sorted(),
                issuedAt: Date(),
                expiresAt: nil
            )
            if built.isUsable {
                material = built
            }
        }

        if let material {
            authNotes += "; materialSchema=\(material.resolvedSchemaVersion)"
            reports.append(ProbeReport(path: authPath, result: .acquiredSession, notes: authNotes))
        } else {
            let detail: String
            if let parsed {
                if parsed.hasCredentialFailure {
                    detail = "server rejected the credentials; messageCode=\(parsed.primaryCode?.rawCode ?? -1)"
                } else if parsed.hasExpired {
                    detail = "server reported an expired or absent session"
                } else if !parsed.status.isAuthenticated {
                    detail = "moduleStatus=\(parsed.status.displayToken)"
                } else {
                    detail = "authenticated but no auth cookie in the response"
                }
            } else {
                detail = "unparseable-module-response"
            }
            reports.append(ProbeReport(path: authPath, result: .rejected(statusCode: authResult.statusCode, detail: detail), notes: authNotes))
        }

        // C2 — resume the session the way a web player does.
        let resumePath = "module-resume-programmatic"
        let resumeNote = "POST resume with OAtrial false, replaying the cookies from the sign-in"
        if let resumeRequest = ProbeEndpoint.makeModuleRequest(
            operation: ProbeEndpoint.resumeOperation,
            query: ProbeEndpoint.resumeQuery,
            body: ProbeEndpoint.moduleBody(standardAuth: nil, resultTemplate: "resume"),
            cookieHeader: ProbeEndpoint.makeCookieHeader(from: authCookies)
        ) {
            let resumeResult = await client.send(resumeRequest)
            var notes = "\(resumeNote); body=\(resumeResult.bodyShape)"
            let resumeParsed = try? ModuleAPIParser.parse(resumeResult.body)
            if let resumeParsed {
                notes += "; moduleStatus=\(resumeParsed.status.displayToken)"
                if let code = resumeParsed.primaryCode {
                    notes += "; messageCode=\(code.rawCode)"
                }
            }

            if let failure = resumeResult.transportFailure {
                reports.append(ProbeReport(path: resumePath, result: .transportFailure(detail: failure.description), notes: notes))
            } else if resumeParsed?.status.isAuthenticated == true {
                reports.append(ProbeReport(path: resumePath, result: .acquiredSession, notes: notes))
            } else {
                let detail = resumeParsed.map { parsed -> String in
                    if parsed.hasExpired {
                        return "session did not survive the resume"
                    }
                    return "moduleStatus=\(parsed.status.displayToken)"
                } ?? "unparseable-module-response"
                reports.append(ProbeReport(path: resumePath, result: .rejected(statusCode: resumeResult.statusCode, detail: detail), notes: notes))
            }
        } else {
            reports.append(ProbeReport(path: resumePath, result: .blocked(detail: "request-construction-failed"), notes: resumeNote))
        }

        // C3 — does the legacy token authenticate against the modern gateway?
        let bridgePath = "module-token-on-edge-gateway"
        let bridgeNote = "presents the legacy AK token as an edge-gateway bearer on profile v4 me"
        guard let akToken else {
            reports.append(ProbeReport(path: bridgePath, result: .blocked(detail: "no AK token was returned by the legacy sign-in"), notes: bridgeNote))
            return reports
        }

        guard let bridgeRequest = ProbeEndpoint.makeEdgeRequest(
            method: "GET",
            path: ProbeEndpoint.profileMePath,
            bearerToken: akToken,
            body: nil,
            clock: clock.next()
        ) else {
            reports.append(ProbeReport(path: bridgePath, result: .blocked(detail: "request-construction-failed"), notes: bridgeNote))
            return reports
        }

        let bridgeResult = await client.send(bridgeRequest)
        let bridgeNotes = "\(bridgeNote); body=\(bridgeResult.bodyShape)"

        if let failure = bridgeResult.transportFailure {
            reports.append(ProbeReport(path: bridgePath, result: .transportFailure(detail: failure.description), notes: bridgeNotes))
        } else if bridgeResult.statusCode == 401 || bridgeResult.statusCode == 403 {
            reports.append(
                ProbeReport(
                    path: bridgePath,
                    result: .rejected(statusCode: bridgeResult.statusCode, detail: "legacy token is not accepted by the edge gateway"),
                    notes: bridgeNotes
                )
            )
        } else if (200..<300).contains(bridgeResult.statusCode) {
            reports.append(
                ProbeReport(
                    path: bridgePath,
                    result: .acquiredSession,
                    notes: bridgeNotes + "; the legacy token authenticates against the edge gateway"
                )
            )
        } else {
            reports.append(
                ProbeReport(
                    path: bridgePath,
                    result: .rejected(statusCode: bridgeResult.statusCode, detail: "unexpected status for a bearer attempt"),
                    notes: bridgeNotes
                )
            )
        }

        return reports
    }
}