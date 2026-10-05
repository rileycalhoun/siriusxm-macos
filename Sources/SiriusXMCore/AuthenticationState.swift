import Foundation

/// Where the app is with respect to having a usable session.
///
/// Lives in the domain rather than in `SiriusXMUI` so that the composition
/// root can reason about it without importing a view type, and so that the
/// eight states the UI has to design for are enumerated once, in one place,
/// instead of being rediscovered as a boolean per screen.
///
/// Every case is a state the user can be in. There is no "error" case that
/// means "something went wrong": the two states that look like failures,
/// `.expired` and `.unavailable`, are the ones the app lives in most often,
/// because session expiry is the normal condition of a live SiriusXM session.
public enum AuthenticationState: Sendable, Hashable {
    /// No session, and nothing in flight.
    case signedOut
    /// Nothing in flight, but a person has to act before anything can happen.
    case awaitingHuman(reason: HumanSignInReason)
    /// An acquisition is running.
    case acquiring
    /// A usable session exists.
    case signedIn
    /// The session existed and is gone. Recoverable without losing the app.
    case expired
    /// The service cannot be reached, or answered something unusable.
    case unavailable(detail: String)

    /// True while work is in flight, for a spinner.
    public var isBusy: Bool { self == .acquiring }

    /// True when only a person can move the app forward.
    public var needsUserAction: Bool {
        if case .awaitingHuman = self { return true }
        return false
    }

    /// True when there is nothing to play.
    public var hasSession: Bool { self == .signedIn }

    /// Short, secret-free slug. The UI turns this into a sentence; the slug
    /// itself is never shown to a person, because the rule is no raw code, no
    /// URL, and no HTTP status in user-facing copy.
    public var slug: String {
        switch self {
        case .signedOut: return "signed-out"
        case .awaitingHuman(let reason): return "awaiting-human(\(reason))"
        case .acquiring: return "acquiring"
        case .signedIn: return "signed-in"
        case .expired: return "expired"
        case .unavailable: return "unavailable"
        }
    }

    /// The single transition this app allows itself to make on its own.
    ///
    /// An expiry signal never clears the session outright; it moves the app
    /// to `.acquiring` so the recovery is a visible, cancellable, retryable
    /// operation instead of a silent one.
    public func expired(by signal: SessionExpirySignal) -> AuthenticationState {
        _ = signal
        return .acquiring
    }
}
