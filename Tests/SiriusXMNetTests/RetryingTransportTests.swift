import Foundation
import Testing
@testable import SiriusXMCore
@testable import SiriusXMNet

@Suite("Retrying transport")
struct RetryingTransportTests {
    private static let request = HTTPRequestSpec(
        method: .post,
        url: RedactingURL(string: "https://api.example.invalid/playback?token=SECRETTOKENVALUE")!
    )

    @Test("a 503 is retried up to the budget and then reported as exhausted")
    func retriesThenGivesUp() async {
        let base = ScriptedTransport(Array(repeating: .response(HTTPResponsePayload(statusCode: 503)), count: 5))
        let sleeper = RecordingSleeper()
        let subject = RetryingTransport(base: base, policy: .default, sleeper: sleeper)

        await #expect(throws: TransportPolicyError.self) {
            _ = try await subject.send(Self.request)
        }

        #expect(base.sendCount == 3)
        #expect(sleeper.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test("a 503 that turns into a 200 stops retrying")
    func stopsOnSuccess() async throws {
        let base = ScriptedTransport([
            .response(HTTPResponsePayload(statusCode: 503)),
            .response(HTTPResponsePayload(statusCode: 200))
        ])
        let sleeper = RecordingSleeper()
        let subject = RetryingTransport(base: base, policy: .default, sleeper: sleeper)

        let response = try await subject.send(Self.request)

        #expect(response.statusCode == 200)
        #expect(base.sendCount == 2)
        #expect(sleeper.delays == [.milliseconds(500)])
    }

    @Test("a 401 is returned to the caller, never retried")
    func unauthorizedIsReturnedNotRetried() async throws {
        let base = ScriptedTransport([.response(HTTPResponsePayload(statusCode: 401))])
        let sleeper = RecordingSleeper()
        let subject = RetryingTransport(base: base, policy: .default, sleeper: sleeper)

        let response = try await subject.send(Self.request)

        #expect(response.statusCode == 401)
        #expect(response.isUnauthorized)
        #expect(base.sendCount == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test("a 404 is returned to the caller, never retried")
    func notFoundIsReturnedNotRetried() async throws {
        let base = ScriptedTransport([.response(HTTPResponsePayload(statusCode: 404))])
        let subject = RetryingTransport(base: base, sleeper: RecordingSleeper())

        let response = try await subject.send(Self.request)

        #expect(response.statusCode == 404)
        #expect(base.sendCount == 1)
    }

    @Test("a timeout is retried and the budget still applies")
    func timeoutsAreRetried() async {
        let base = ScriptedTransport(Array(repeating: .failure(.timedOut), count: 5))
        let sleeper = RecordingSleeper()
        let subject = RetryingTransport(base: base, policy: .default, sleeper: sleeper)

        await #expect(throws: TransportPolicyError.self) {
            _ = try await subject.send(Self.request)
        }

        #expect(base.sendCount == 3)
        #expect(sleeper.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test("a TLS failure is not retried")
    func tlsFailureIsNotRetried() async {
        let base = ScriptedTransport([.failure(.tlsFailure)])
        let subject = RetryingTransport(base: base, sleeper: RecordingSleeper())

        await #expect(throws: TransportPolicyError.self) {
            _ = try await subject.send(Self.request)
        }

        #expect(base.sendCount == 1)
    }

    @Test("a cancellation surfaces as a cancellation, not as a budget failure")
    func cancellationIsItsOwnOutcome() async {
        let base = ScriptedTransport([.failure(.cancelled)])
        let subject = RetryingTransport(base: base, sleeper: RecordingSleeper())

        await #expect(throws: TransportPolicyError.cancelled(fingerprint: RequestFingerprint.of(Self.request))) {
            _ = try await subject.send(Self.request)
        }
    }

    @Test("a 429 waits for exactly what the server asked for")
    func retryAfterIsRespected() async throws {
        let base = ScriptedTransport([
            .response(HTTPResponsePayload(statusCode: 429, headers: [HTTPHeader("Retry-After", value: "7")])),
            .response(HTTPResponsePayload(statusCode: 200))
        ])
        let sleeper = RecordingSleeper()
        let subject = RetryingTransport(base: base, policy: .default, sleeper: sleeper)

        let response = try await subject.send(Self.request)

        #expect(response.statusCode == 200)
        #expect(sleeper.delays == [.seconds(7)])
    }

    @Test("the budget is exactly the policy's budget, not one more")
    func budgetIsExactlyThree() async {
        let base = ScriptedTransport(Array(repeating: .response(HTTPResponsePayload(statusCode: 500)), count: 10))
        let subject = RetryingTransport(base: base, policy: .default, sleeper: RecordingSleeper())

        do {
            _ = try await subject.send(Self.request)
            Issue.record("expected a budget failure")
        } catch let error as TransportPolicyError {
            guard case .budgetExhausted(let attempts, _) = error else {
                Issue.record("expected budgetExhausted, got \(error)")
                return
            }
            #expect(attempts == 3)
        } catch {
            Issue.record("unexpected error \(error)")
        }

        #expect(base.sendCount == 3)
    }

    @Test("the attempt ledger is keyed by the token-free fingerprint")
    func attemptLedgerUsesTheFingerprint() async {
        let base = ScriptedTransport(Array(repeating: .response(HTTPResponsePayload(statusCode: 500)), count: 5))
        let subject = RetryingTransport(base: base, policy: .default, sleeper: RecordingSleeper())

        await #expect(throws: TransportPolicyError.self) {
            _ = try await subject.send(Self.request)
        }

        #expect(subject.attemptCount(for: Self.request) == 3)
        // A different token on the same request is still the same request, so
        // the ledger carries over rather than resetting.
        #expect(subject.attemptCount(for: Self.otherTokenRequest) == 3)
    }

    @Test("a policy failure renders without a URL or a token")
    func policyFailureRendersSafely() async {
        let base = ScriptedTransport(Array(repeating: .response(HTTPResponsePayload(statusCode: 500)), count: 5))
        let subject = RetryingTransport(base: base, policy: .default, sleeper: RecordingSleeper())

        do {
            _ = try await subject.send(Self.request)
            Issue.record("expected a budget failure")
        } catch let error as TransportPolicyError {
            let rendered = String(describing: error)
            #expect(!rendered.contains("SECRETTOKENVALUE"))
            #expect(!rendered.contains("https://"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - The final attempt

    @Test("a 200 arriving on the last attempt is returned, not thrown away")
    func successOnTheLastAttemptIsReturned() async throws {
        // The budget is three attempts, so this succeeds on the third — the
        // attempt where the budget is also spent. A 200 is an answer to the
        // server's question, and discarding it would throw away a session the
        // user paid three attempts for.
        let base = ScriptedTransport([
            .response(HTTPResponsePayload(statusCode: 503)),
            .response(HTTPResponsePayload(statusCode: 503)),
            .response(HTTPResponsePayload(statusCode: 200))
        ])
        let sleeper = RecordingSleeper()
        let subject = RetryingTransport(base: base, policy: .default, sleeper: sleeper)

        let response = try await subject.send(Self.request)

        #expect(response.statusCode == 200)
        #expect(base.sendCount == 3)
        #expect(sleeper.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test("a 401 arriving on the last attempt is returned, not thrown away")
    func unauthorizedOnTheLastAttemptIsReturned() async throws {
        let base = ScriptedTransport([
            .response(HTTPResponsePayload(statusCode: 503)),
            .response(HTTPResponsePayload(statusCode: 503)),
            .response(HTTPResponsePayload(statusCode: 401))
        ])
        let subject = RetryingTransport(base: base, policy: .default, sleeper: RecordingSleeper())

        let response = try await subject.send(Self.request)

        #expect(response.statusCode == 401)
        #expect(response.isUnauthorized)
        #expect(base.sendCount == 3)
    }

    // MARK: - Why a policy failure stopped

    @Test("an unrecoverable transport failure is reported as itself, not as a spent budget")
    func unrecoverableTransportIsNotReportedAsBudgetExhausted() async {
        let base = ScriptedTransport([.failure(.tlsFailure)])
        let subject = RetryingTransport(base: base, sleeper: RecordingSleeper())
        let fingerprint = RequestFingerprint.of(Self.request)

        await #expect(
            throws: TransportPolicyError.unrecoverableTransport(reason: .tlsFailure, fingerprint: fingerprint)
        ) {
            _ = try await subject.send(Self.request)
        }

        #expect(base.sendCount == 1)
    }

    @Test("an unreachable host is reported as itself, not as a spent budget")
    func unreachableHostIsNotReportedAsBudgetExhausted() async {
        let base = ScriptedTransport([.failure(.hostUnreachable)])
        let subject = RetryingTransport(base: base, sleeper: RecordingSleeper())
        let fingerprint = RequestFingerprint.of(Self.request)

        await #expect(
            throws: TransportPolicyError.unrecoverableTransport(reason: .hostUnreachable, fingerprint: fingerprint)
        ) {
            _ = try await subject.send(Self.request)
        }
    }

    @Test("budgetExhausted still means only that the bound was reached")
    func budgetExhaustedMeansOnlyTheBoundWasReached() async {
        // A timeout is worth retrying, so exhausting the budget is genuinely
        // the reason this stopped — which is the distinction the new case
        // exists to preserve.
        let base = ScriptedTransport(Array(repeating: .failure(.timedOut), count: 5))
        let subject = RetryingTransport(base: base, policy: .default, sleeper: RecordingSleeper())
        let fingerprint = RequestFingerprint.of(Self.request)

        await #expect(
            throws: TransportPolicyError.budgetExhausted(attempts: 3, fingerprint: fingerprint)
        ) {
            _ = try await subject.send(Self.request)
        }
    }

    @Test("an unrecoverable transport failure renders without a URL or a token")
    func unrecoverableTransportRendersSafely() async {
        let base = ScriptedTransport([.failure(.tlsFailure)])
        let subject = RetryingTransport(base: base, sleeper: RecordingSleeper())

        do {
            _ = try await subject.send(Self.request)
            Issue.record("expected a transport failure")
        } catch let error as TransportPolicyError {
            let rendered = String(describing: error)
            #expect(!rendered.contains("SECRETTOKENVALUE"))
            #expect(!rendered.contains("https://"))
            #expect(rendered.contains("tls-failure"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private static let otherTokenRequest = HTTPRequestSpec(
        method: .post,
        url: RedactingURL(string: "https://api.example.invalid/playback?token=DIFFERENTTOKEN")!
    )
}
