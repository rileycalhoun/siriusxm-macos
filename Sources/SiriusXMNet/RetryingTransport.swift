import Foundation

/// Why the retry layer gave up on a request that never succeeded.
public enum TransportPolicyError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The bounded budget for this request is spent. This means only that the
    /// bound was reached — never that the service was busy, and never that a
    /// request which was never going to work ran out of attempts.
    case budgetExhausted(attempts: Int, fingerprint: RequestFingerprint)
    /// The caller cancelled. Never retried, never reported as a failure of
    /// the service.
    case cancelled(fingerprint: RequestFingerprint)
    /// The transport failed in a way that retrying cannot fix: a name that
    /// does not resolve, a certificate that does not validate. Distinct from
    /// a spent budget because the answer would have been the same on the first
    /// attempt, so no number of retries would have changed it.
    case unrecoverableTransport(reason: TransportError, fingerprint: RequestFingerprint)

    public var description: String {
        switch self {
        case .budgetExhausted(let attempts, let fingerprint):
            return "budget-exhausted(attempts: \(attempts), \(fingerprint))"
        case .cancelled(let fingerprint):
            return "cancelled(\(fingerprint))"
        case .unrecoverableTransport(let reason, let fingerprint):
            return "unrecoverable-transport(\(reason), \(fingerprint))"
        }
    }
}

/// Wraps a transport in the bounded retry policy.
///
/// This is the only place in the app that resends anything. It sits above
/// `URLSessionTransport` and below every caller, so a caller cannot opt out of
/// the budget by accident.
///
/// Note what it does *not* do: it does not re-authenticate, and it does not
/// resend a request whose 401 says the session is gone. Those are decisions
/// for `BoundedSessionRefresher`, driven by the protocol layer that
/// understands what the status code meant.
public final class RetryingTransport: HTTPTransport, @unchecked Sendable {
    private let base: any HTTPTransport
    private let policy: RetryPolicy
    private let sleeper: any Sleeper

    private let lock = NSLock()
    private var attemptsByFingerprint: [RequestFingerprint: Int] = [:]

    public init(
        base: any HTTPTransport,
        policy: RetryPolicy = .default,
        sleeper: any Sleeper = DispatchSleeper()
    ) {
        self.base = base
        self.policy = policy
        self.sleeper = sleeper
    }

    /// How many times a given request has been sent through this instance.
    ///
    /// Keyed by the stable, token-free fingerprint, so it is safe to log and
    /// safe to assert on in a test.
    public func attemptCount(for request: HTTPRequestSpec) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptsByFingerprint[RequestFingerprint.of(request)] ?? 0
    }

    public func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload {
        let fingerprint = RequestFingerprint.of(request)
        var attempt = 0

        while true {
            attempt += 1
            record(attempt, for: fingerprint)

            let response: HTTPResponsePayload
            do {
                response = try await base.send(request)
            } catch let error as TransportError {
                switch policy.decide(transportError: error, attempt: attempt) {
                case .retry(let after):
                    try await sleeper.sleep(for: after)
                    continue
                case .stop(reason: .cancelled):
                    throw TransportPolicyError.cancelled(fingerprint: fingerprint)
                case .stop(let reason):
                    throw policyFailure(reason, attempts: attempt, fingerprint: fingerprint)
                }
            }

            switch policy.decide(
                statusCode: response.statusCode,
                attempt: attempt,
                retryAfterSeconds: response.retryAfterSeconds
            ) {
            case .retry(let after):
                try await sleeper.sleep(for: after)
                continue
            case .stop(reason: .succeeded):
                return response
            case .stop(reason: .permanentStatus):
                // A 401 or a 404 is an answer, not a failure of the transport.
                // The protocol layer is the one that knows what it meant.
                return response
            case .stop(let reason):
                throw policyFailure(reason, attempts: attempt, fingerprint: fingerprint)
            }
        }
    }

    private func policyFailure(
        _ reason: RetryDecision.StopReason,
        attempts: Int,
        fingerprint: RequestFingerprint
    ) -> TransportPolicyError {
        switch reason {
        case .cancelled:
            return .cancelled(fingerprint: fingerprint)
        case .unrecoverableTransport(let transportError):
            // A wrong host or a bad certificate is not a spent budget. Both
            // are stops, so nothing retries differently either way, but
            // reporting it as a budget failure tells whoever is debugging a
            // rate-limit incident that the service asked them to slow down,
            // when in fact no amount of waiting would ever have worked.
            return .unrecoverableTransport(reason: transportError, fingerprint: fingerprint)
        case .budgetExhausted:
            return .budgetExhausted(attempts: attempts, fingerprint: fingerprint)
        case .succeeded, .permanentStatus:
            // Unreachable, and deliberately not papered over. `send(_:)`
            // returns the payload on both of these before it ever reaches
            // this function: a 2xx is an answer the caller wants, and a
            // permanent status is an answer only the protocol layer can
            // interpret. Reporting either as a thrown `TransportPolicyError`
            // would throw away a response that already arrived.
            //
            // There is no `default:` here on purpose. A `default` is what let
            // a new `StopReason` compile silently and be mislabelled as a
            // spent budget — the exact defect that adding
            // `unrecoverableTransport` was meant to close. Enumerating every
            // case makes the next one a compile error instead.
            preconditionFailure(
                "policyFailure(reason:) reached with \(reason); succeeded and permanentStatus both return in send(_:) before it is called"
            )
        }
    }

    private func record(_ attempt: Int, for fingerprint: RequestFingerprint) {
        lock.lock()
        attemptsByFingerprint[fingerprint] = attempt
        lock.unlock()
    }
}
