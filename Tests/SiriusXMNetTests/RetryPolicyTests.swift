import Foundation
import Testing
@testable import SiriusXMNet

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("the default policy caps authentication at three attempts")
    func authAttemptsAreCappedAtThree() {
        #expect(RetryPolicy.default.maximumAuthAttempts == 3)
    }

    @Test("the budget is spent before any further attempt is offered")
    func budgetIsSpent() {
        let policy = RetryPolicy.default

        for attempt in 1...3 {
            let decision = policy.decide(statusCode: 500, attempt: attempt, retryAfterSeconds: nil)
            #expect(decision == .retry(after: policy.backoff(afterAttempt: attempt)))
        }

        let fourth = policy.decide(statusCode: 500, attempt: 4, retryAfterSeconds: nil)
        #expect(fourth == .stop(reason: .budgetExhausted(attempts: 4)))
    }

    @Test("backoff doubles per attempt")
    func backoffDoubles() {
        let policy = RetryPolicy(baseDelay: .milliseconds(500), maximumDelay: .seconds(30))

        #expect(policy.backoff(afterAttempt: 1) == .milliseconds(500))
        #expect(policy.backoff(afterAttempt: 2) == .seconds(1))
        #expect(policy.backoff(afterAttempt: 3) == .seconds(2))
        #expect(policy.backoff(afterAttempt: 4) == .seconds(4))
    }

    @Test("backoff stops growing at the ceiling")
    func backoffIsClamped() {
        let policy = RetryPolicy(baseDelay: .seconds(1), maximumDelay: .seconds(8))

        #expect(policy.backoff(afterAttempt: 10) == .seconds(8))
    }

    @Test("a zero or negative attempt waits for nothing")
    func attemptZeroWaitsForNothing() {
        #expect(RetryPolicy.default.backoff(afterAttempt: 0) == .zero)
    }

    @Test("Retry-After outranks the computed backoff")
    func retryAfterWins() {
        let policy = RetryPolicy.default

        #expect(policy.delay(afterAttempt: 1, retryAfterSeconds: 12) == .seconds(12))
    }

    @Test("an unreasonable Retry-After is clamped")
    func retryAfterIsClamped() {
        let policy = RetryPolicy(maximumRetryAfter: .seconds(60))

        #expect(policy.delay(afterAttempt: 1, retryAfterSeconds: 86_400) == .seconds(60))
        #expect(policy.delay(afterAttempt: 1, retryAfterSeconds: 0) == .zero)
    }

    @Test("a 401 is an answer, never something to retry")
    func unauthorizedIsNeverRetried() {
        let decision = RetryPolicy.default.decide(statusCode: 401, attempt: 1, retryAfterSeconds: nil)

        #expect(decision == .stop(reason: .permanentStatus(401)))
    }

    @Test("429 and 5xx are retried, 404 is not")
    func onlyTransientStatusesRetry() {
        let policy = RetryPolicy.default

        #expect(policy.decide(statusCode: 429, attempt: 1, retryAfterSeconds: nil) != .stop(reason: .permanentStatus(429)))
        #expect(policy.decide(statusCode: 503, attempt: 1, retryAfterSeconds: nil) != .stop(reason: .permanentStatus(503)))
        #expect(policy.decide(statusCode: 404, attempt: 1, retryAfterSeconds: nil) == .stop(reason: .permanentStatus(404)))
    }

    @Test("2xx is success")
    func successStops() {
        #expect(RetryPolicy.default.decide(statusCode: 204, attempt: 1, retryAfterSeconds: nil) == .stop(reason: .succeeded))
    }

    @Test("a cancelled request is never retried")
    func cancellationIsNeverRetried() {
        #expect(RetryPolicy.default.decide(transportError: .cancelled, attempt: 1) == .stop(reason: .cancelled))
    }

    @Test("a TLS failure is never retried")
    func tlsFailureIsNeverRetried() {
        #expect(
            RetryPolicy.default.decide(transportError: .tlsFailure, attempt: 1)
                == .stop(reason: .unrecoverableTransport(.tlsFailure))
        )
    }

    @Test("a timeout is retried")
    func timeoutIsRetried() {
        #expect(RetryPolicy.default.decide(transportError: .timedOut, attempt: 1) == .retry(after: .milliseconds(500)))
    }

    @Test("a refused redirect is not retried")
    func refusedRedirectIsNotRetried() {
        #expect(
            RetryPolicy.default.decide(transportError: .redirectRefused, attempt: 1)
                == .stop(reason: .unrecoverableTransport(.redirectRefused))
        )
    }

    @Test("every transport failure classifies without a URL in the slug")
    func transportFailuresRenderSlugs() {
        #expect(TransportError.timedOut.description == "timed-out")
        #expect(TransportError.networkUnreachable.description == "network-unreachable")
        #expect(TransportError.hostUnreachable.description == "host-unreachable")
        #expect(TransportError.redirectRefused.description == "redirect-refused")
        #expect(TransportError.cancelled.description == "cancelled")
        #expect(TransportError.tlsFailure.description == "tls-failure")
        #expect(TransportError.unclassified(code: -1).description == "unclassified(-1)")
    }

    @Test("a URLError is reduced before it is stored")
    func urlErrorsAreClassified() {
        #expect(TransportError(URLError(.timedOut)) == .timedOut)
        #expect(TransportError(URLError(.notConnectedToInternet)) == .networkUnreachable)
        #expect(TransportError(URLError(.cannotFindHost)) == .hostUnreachable)
        #expect(TransportError(URLError(.serverCertificateUntrusted)) == .tlsFailure)
        #expect(TransportError(URLError(.cancelled)) == .cancelled)
        #expect(TransportError(URLError(.badServerResponse)).isWorthRetrying == false)
    }
}
