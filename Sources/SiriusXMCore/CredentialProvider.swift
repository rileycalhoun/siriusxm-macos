import Foundation

/// The one seam every authentication path in this app goes through.
///
/// ## Exactly one implementation ships in Phase 0
///
/// **Shipped:** `WebSignInCredentialProvider`. Token acquisition on this
/// service is browser-mediated — a human signs in at the first-party web
/// player and the resulting session is read out. Phase 0.5 confirmed that this
/// is the only route with any evidence behind it, and that a native grant is
/// not confirmed to exist on either protocol generation. The browser is a
/// credential *source*, so it lives behind this protocol and behind the
/// `WebSignInSurface` seam, and neither the type nor the view ever crosses
/// into another module.
///
/// **Deliberately not written:** a second provider for the legacy module API
/// (`modify/authentication`). Its request shape is stable and it answers with a
/// credential-specific error, but it has never been observed to actually grant
/// a session, and it is not known whether the token it would hand back is
/// accepted by the edge gateway at all. Writing it now would be scaffolding
/// lock-in against an unproven endpoint — exactly what this phase exists to
/// prevent. It gets written when the credentialed run proves it is worth
/// having, and it gets written *here*, behind this same protocol, at the cost
/// of one conformance and zero changes downstream.
///
/// ## Why expiry is a first-class operation
///
/// Both live protocol generations signal an expired session in-band: message
/// codes 201 and 208 on the legacy API, HTTP 401 on the edge gateway. Session
/// expiry is therefore the normal state of a running app, not a failure mode
/// bolted on afterwards. `reauthenticate(after:)` exists so that the recovery
/// path is a declared, tested operation that carries the reason it was called,
/// rather than a second `acquire()` call discovered at the call site. Both may
/// run at any time, including concurrently with an in-flight refresh, and
/// implementations are expected to collapse concurrent calls rather than send
/// them.
///
/// ## What never crosses this boundary
///
/// The password. It exists inside `acquire()`/`reauthenticate(after:)` as a
/// local for the duration of one human interaction, and it has no field here,
/// no field on `SessionMaterial`, and nowhere to be cached.
public protocol CredentialProvider: Sendable {
    /// Whether reaching a session right now needs a person at the keyboard.
    ///
    /// The UI reads this to decide between showing a sign-in affordance and
    /// spinning. It is a property rather than something inferred from an
    /// attempt, so the UI never has to provoke a failure to find out.
    var requiresHumanInteraction: Bool { get }

    /// Cold start: obtain a session from nothing.
    ///
    /// Takes no arguments and reads no ambient global, so a provider can be
    /// substituted and tested without a process environment.
    func acquire() async throws -> SessionMaterial

    /// Mid-session re-entry, after an expiry signal observed in-band.
    ///
    /// Structurally identical to `acquire()` on purpose: the app must not
    /// carry two code paths for "I need a session", because only the cold one
    /// would be exercised until the first real expiry.
    func reauthenticate(after signal: SessionExpirySignal) async throws -> SessionMaterial

    /// Extend a session that is still good, without human interaction.
    ///
    /// Takes no password. Implementations return the session unchanged when
    /// renewal is not available, rather than failing, so a caller can always
    /// fall back to `reauthenticate(after:)` on its own terms.
    func refresh(_ session: SessionMaterial) async throws -> SessionMaterial
}

/// The in-band reasons this app treats as "the session is gone".
///
/// Modelled as a value rather than a boolean so that a retry budget, a log
/// line, and a user-facing message can each react differently to "the gateway
/// said 401" and "the subscriber's device limit was reached", without anyone
/// re-parsing a string.
public enum SessionExpirySignal: Sendable, Hashable, CustomStringConvertible {
    /// The edge gateway answered 401.
    case edgeGatewayUnauthorized(statusCode: Int)

    /// The legacy module API reported 201 or 208.
    case moduleMessageCode(code: Int)

    /// The locally recorded expiry passed, with no request sent.
    case clockExpired(at: Date)

    /// The service withdrew the session for a reason it did not itemise.
    case revoked

    /// Short, secret-free slug for a log line. Never a raw body.
    public var description: String {
        switch self {
        case .edgeGatewayUnauthorized(let status): return "edge-gateway-\(status)"
        case .moduleMessageCode(let code): return "module-code-\(code)"
        case .clockExpired: return "clock-expired"
        case .revoked: return "revoked"
        }
    }
}

/// Why a human has to be involved before a session can exist.
///
/// Every case here is a thing the subscriber can act on. None of them is ever
/// worked around, and none of them is ever presented as a technical error.
public enum HumanSignInReason: Sendable, Hashable, CustomStringConvertible {
    /// No session exists yet.
    case signInRequired
    /// The account asked for a second factor. Not circumvented.
    case additionalVerificationRequired
    /// The service issued a challenge this client will not solve.
    case challengeIssued
    /// The service refused the credentials.
    case credentialRejected

    public var description: String {
        switch self {
        case .signInRequired: return "sign-in-required"
        case .additionalVerificationRequired: return "additional-verification-required"
        case .challengeIssued: return "challenge-issued"
        case .credentialRejected: return "credential-rejected"
        }
    }
}

/// Failures a credential provider can report.
///
/// `detail` is a short, already-redacted slug supplied by the provider. There
/// is deliberately no associated `Error` or `userInfo`: an arbitrary error
/// smuggled in here ends up in an alert, a crash report, and eventually in a
/// GitHub issue.
public enum CredentialError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A person has to do something before this can succeed.
    case humanSignInRequired(reason: HumanSignInReason)
    /// The service refused the credentials.
    case rejected
    /// The service asked us to slow down and told us for how long.
    case rateLimited(retryAfterSeconds: Int?)
    /// The bounded retry budget ran out. Reached only on repeated failure.
    case retryBudgetExhausted(attempts: Int)
    /// Anything else, already reduced to a slug.
    case unavailable(detail: String)

    public var description: String {
        switch self {
        case .humanSignInRequired(let reason): return "human-sign-in-required(\(reason))"
        case .rejected: return "rejected"
        case .rateLimited(let seconds): return "rate-limited(\(seconds.map(String.init) ?? "unspecified"))"
        case .retryBudgetExhausted(let attempts): return "retry-budget-exhausted(\(attempts))"
        case .unavailable(let detail): return "unavailable(\(detail))"
        }
    }
}
