import Foundation

/// Why the retry layer gave up on a request that never succeeded.
public enum TransportPolicyError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The bounded budget for this request is spent.
    case budgetExhausted(attempts: Int, fingerprint: RequestFingerprint)
    /// The caller cancelled. Never retried, never reported as a failure of
    /// the service.
    case cancelled(fingerprint: RequestFingerprint)

    public var description: String {
        switch self {
        case .budgetExhausted(let attempts, let fingerprint):
            return "budget-exhausted(attempts: \(attempts), \(fingerprint))"
        case .cancelled(let fingerprint):
            return "cancelled(\(fingerprint))"
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
        default:
            return .budgetExhausted(attempts: attempts, fingerprint: fingerprint)
        }
    }

    private func record(_ attempt: Int, for fingerprint: RequestFingerprint) {
        lock.lock()
        attemptsByFingerprint[fingerprint] = attempt
        lock.unlock()
    }
}
