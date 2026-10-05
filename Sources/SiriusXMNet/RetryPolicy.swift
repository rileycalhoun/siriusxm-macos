import Foundation

/// What the retry layer decided to do about one failed attempt.
public enum RetryDecision: Sendable, Hashable {
    /// Send it again, after waiting.
    case retry(after: Duration)
    /// Do not send it again.
    case stop(reason: StopReason)

    public enum StopReason: Sendable, Hashable, CustomStringConvertible {
        /// The attempt succeeded.
        case succeeded
        /// The bounded budget for this acquisition cycle is spent.
        case budgetExhausted(attempts: Int)
        /// The caller cancelled. Never retried.
        case cancelled
        /// The server said something retrying cannot fix.
        case permanentStatus(Int)
        /// The transport failed in a way that will not change on its own.
        case unrecoverableTransport(TransportError)

        public var description: String {
            switch self {
            case .succeeded: return "succeeded"
            case .budgetExhausted(let attempts): return "budget-exhausted(\(attempts))"
            case .cancelled: return "cancelled"
            case .permanentStatus(let status): return "permanent-status(\(status))"
            case .unrecoverableTransport(let error): return "unrecoverable-transport(\(error))"
            }
        }
    }
}

/// The bounded retry policy.
///
/// ## Why the bound exists
///
/// SiriusXM rate-limits aggressively and an account that looks like a client
/// hammering a failed endpoint can be suspended. This policy is therefore not
/// about being thorough. Three authentication attempts, exponential backoff,
/// and then a stop, is the point where "retry" stops being resilience and
/// starts being a reason to lose somebody's subscription.
///
/// A non-zero answer here is not a bug. A caller that wants to try again asks
/// the user first.
public struct RetryPolicy: Sendable, Hashable {
    /// Hard ceiling on authentication attempts within one acquisition cycle.
    public var maximumAuthAttempts: Int

    /// First backoff. Doubles per attempt.
    public var baseDelay: Duration

    /// Ceiling on computed backoff, so a long outage does not park the app for
    /// minutes between attempts.
    public var maximumDelay: Duration

    /// Ceiling on a server-supplied `Retry-After`.
    ///
    /// A server that asks for an hour is not being obeyed here; a server that
    /// asks for an hour has told us to give up, and the user is the one who
    /// decides to try again.
    public var maximumRetryAfter: Duration

    public static let `default` = RetryPolicy(
        maximumAuthAttempts: 3,
        baseDelay: .milliseconds(500),
        maximumDelay: .seconds(8),
        maximumRetryAfter: .seconds(60)
    )

    public init(
        maximumAuthAttempts: Int = RetryPolicy.default.maximumAuthAttempts,
        baseDelay: Duration = RetryPolicy.default.baseDelay,
        maximumDelay: Duration = RetryPolicy.default.maximumDelay,
        maximumRetryAfter: Duration = RetryPolicy.default.maximumRetryAfter
    ) {
        self.maximumAuthAttempts = maximumAuthAttempts
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumRetryAfter = maximumRetryAfter
    }

    /// Exponential backoff for the gap after `attempt`, which is 1-based.
    /// Attempt 1 waits the base delay, attempt 2 twice that, and so on.
    public func backoff(afterAttempt attempt: Int) -> Duration {
        guard attempt >= 1 else { return .zero }
        let factor = pow(2.0, Double(attempt - 1))
        let scaled = baseDelay.seconds * factor
        return Duration.seconds(min(scaled, maximumDelay.seconds))
    }

    /// The wait before the next attempt, honouring `Retry-After` when the
    /// server sent one. A server instruction wins over the computed backoff,
    /// because it is the only party that knows what it is about to do.
    public func delay(afterAttempt attempt: Int, retryAfterSeconds: Int?) -> Duration {
        guard let retryAfterSeconds else { return backoff(afterAttempt: attempt) }
        let requested = Duration.seconds(Double(retryAfterSeconds))
        return Duration.seconds(min(requested.seconds, maximumRetryAfter.seconds))
    }

    /// Decides what to do about an HTTP exchange that has already completed.
    ///
    /// A 401 is a stop, not a retry: the caller has to re-enter the credential
    /// provider, and doing that on a timer is how an expired session turns into
    /// a burst of sign-in attempts.
    public func decide(statusCode: Int, attempt: Int, retryAfterSeconds: Int?) -> RetryDecision {
        if attempt >= maximumAuthAttempts {
            return .stop(reason: .budgetExhausted(attempts: attempt))
        }
        switch statusCode {
        case 200...299:
            return .stop(reason: .succeeded)
        case 401, 403:
            return .stop(reason: .permanentStatus(statusCode))
        case 429:
            return .retry(after: delay(afterAttempt: attempt, retryAfterSeconds: retryAfterSeconds))
        case 500...599:
            return .retry(after: delay(afterAttempt: attempt, retryAfterSeconds: retryAfterSeconds))
        default:
            return .stop(reason: .permanentStatus(statusCode))
        }
    }

    /// Decides what to do about a transport failure that produced no response.
    public func decide(transportError: TransportError, attempt: Int) -> RetryDecision {
        if transportError.isCancellation {
            return .stop(reason: .cancelled)
        }
        if attempt >= maximumAuthAttempts {
            return .stop(reason: .budgetExhausted(attempts: attempt))
        }
        guard transportError.isWorthRetrying else {
            return .stop(reason: .unrecoverableTransport(transportError))
        }
        return .retry(after: backoff(afterAttempt: attempt))
    }
}

extension Duration {
    /// Seconds as a `Double`, for the arithmetic in `RetryPolicy`.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
