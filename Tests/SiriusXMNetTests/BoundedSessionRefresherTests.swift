import Foundation
import Testing
@testable import SiriusXMCore
@testable import SiriusXMNet

@Suite("Bounded session refresher")
struct BoundedSessionRefresherTests {
    private func refresher(
        provider: StubCredentialProvider,
        sleeper: RecordingSleeper = RecordingSleeper(),
        clock: any WallClock = FixedClock()
    ) -> BoundedSessionRefresher {
        BoundedSessionRefresher(
            provider: provider,
            policy: .default,
            sleeper: sleeper,
            clock: clock
        )
    }

    @Test("a cold start calls acquire and caches the session")
    func coldStartAcquires() async throws {
        let provider = StubCredentialProvider(outcomes: [.success(.testFresh())])
        let subject = refresher(provider: provider)

        let session = try await subject.session()

        #expect(session.resolvedToken == "t")
        #expect(provider.callCounts.acquire == 1)
        #expect(subject.currentSession?.resolvedToken == "t")
    }

    @Test("a second caller gets the cached session without touching the provider")
    func cachedSessionIsReused() async throws {
        let provider = StubCredentialProvider(outcomes: [.success(.testFresh())])
        let subject = refresher(provider: provider)

        _ = try await subject.session()
        _ = try await subject.session()

        #expect(provider.totalCalls == 1)
    }

    @Test("an expiry signal goes to reauthenticate, not to acquire")
    func expiryUsesReauthenticate() async throws {
        let provider = StubCredentialProvider(outcomes: [
            .success(.testFresh(token: "first")),
            .success(.testFresh(token: "second"))
        ])
        let subject = refresher(provider: provider)

        _ = try await subject.session()
        let renewed = try await subject.session(after: .moduleMessageCode(code: 208))

        #expect(renewed.resolvedToken == "second")
        #expect(provider.callCounts.acquire == 1)
        #expect(provider.callCounts.reauthenticate == 1)
        #expect(provider.recordedSignals == [.moduleMessageCode(code: 208)])
    }

    @Test("an HTTP 401 re-enters through the same seam")
    func unauthorizedReEnters() async throws {
        let provider = StubCredentialProvider(outcomes: [.success(.testFresh(token: "after-401"))])
        let subject = refresher(provider: provider)

        let session = try await subject.session(after: .edgeGatewayUnauthorized(statusCode: 401))

        #expect(session.resolvedToken == "after-401")
        #expect(provider.callCounts.reauthenticate == 1)
        #expect(provider.callCounts.acquire == 0)
    }

    @Test("a failing acquisition stops at three attempts")
    func acquisitionIsBounded() async {
        let provider = StubCredentialProvider(
            outcomes: Array(repeating: .failure(.rejected), count: 10)
        )
        let sleeper = RecordingSleeper()
        let subject = refresher(provider: provider, sleeper: sleeper)

        await #expect(throws: CredentialError.retryBudgetExhausted(attempts: 3)) {
            _ = try await subject.session()
        }

        #expect(provider.totalCalls == 3)
        #expect(sleeper.delays == [.milliseconds(500), .seconds(1)])
    }

    @Test("the budget is the last word even when the provider asks for more")
    func budgetOutranksTheProvider() async {
        let provider = StubCredentialProvider(
            outcomes: Array(repeating: .failure(.unavailable(detail: "try-again")), count: 10)
        )
        let subject = refresher(provider: provider)

        await #expect(throws: CredentialError.retryBudgetExhausted(attempts: 3)) {
            _ = try await subject.session()
        }

        #expect(provider.totalCalls == 3)
        #expect(subject.attempts == 3)
    }

    @Test("a rate-limited provider is obeyed over the computed backoff")
    func rateLimitWins() async {
        let provider = StubCredentialProvider(
            outcomes: [
                .failure(.rateLimited(retryAfterSeconds: 12)),
                .failure(.rateLimited(retryAfterSeconds: 12)),
                .failure(.rateLimited(retryAfterSeconds: 12))
            ]
        )
        let sleeper = RecordingSleeper()
        let subject = refresher(provider: provider, sleeper: sleeper)

        await #expect(throws: CredentialError.retryBudgetExhausted(attempts: 3)) {
            _ = try await subject.session()
        }

        #expect(sleeper.delays == [.seconds(12), .seconds(12)])
    }

    @Test("a session with no expiry is treated as usable")
    func unknownExpiryIsNotAProblem() async throws {
        let provider = StubCredentialProvider(
            outcomes: [.success(SessionMaterial(token: "t"))]
        )
        let subject = refresher(provider: provider)

        _ = try await subject.session()
        _ = try await subject.session()

        #expect(provider.totalCalls == 1)
    }

    @Test("an unusable session is not accepted")
    func emptySessionIsNotAccepted() async {
        let provider = StubCredentialProvider(
            outcomes: Array(repeating: .success(SessionMaterial()), count: 5)
        )
        let subject = refresher(provider: provider)

        await #expect(throws: CredentialError.retryBudgetExhausted(attempts: 3)) {
            _ = try await subject.session()
        }

        #expect(subject.currentSession == nil)
    }

    @Test("renew uses refresh, and falls back to a full re-entry when it cannot")
    func renewFallsBack() async throws {
        let provider = StubCredentialProvider(
            outcomes: [
                .failure(.humanSignInRequired(reason: .signInRequired)),
                .success(.testFresh(token: "renewed"))
            ]
        )
        let subject = refresher(provider: provider)

        let renewed = try await subject.renew(.testFresh())

        #expect(renewed.resolvedToken == "renewed")
        #expect(provider.callCounts.refresh == 1)
        #expect(provider.callCounts.acquire == 1)
    }

    @Test("renew accepts a session the provider extended")
    func renewAcceptsExtension() async throws {
        let provider = StubCredentialProvider(outcomes: [.success(.testFresh(token: "extended"))])
        let subject = refresher(provider: provider)

        let renewed = try await subject.renew(.testFresh())

        #expect(renewed.resolvedToken == "extended")
        #expect(provider.callCounts.refresh == 1)
        #expect(provider.callCounts.acquire == 0)
    }

    @Test("an expired cached session is discarded rather than returned")
    func expiredCacheIsDiscarded() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_010_000))
        let provider = StubCredentialProvider(
            outcomes: [
                .success(SessionMaterial(token: "old", expiresAt: Date(timeIntervalSince1970: 1_700_000_100))),
                .success(.testFresh(token: "new"))
            ]
        )
        let subject = refresher(provider: provider, clock: clock)

        _ = try await subject.session()
        let fresh = try await subject.session()

        #expect(fresh.resolvedToken == "new")
        #expect(provider.totalCalls == 2)
    }

    @Test("invalidate forgets the session")
    func invalidateClearsTheCache() async throws {
        let provider = StubCredentialProvider(
            outcomes: [.success(.testFresh(token: "a")), .success(.testFresh(token: "b"))]
        )
        let subject = refresher(provider: provider)

        _ = try await subject.session()
        subject.invalidate()
        #expect(subject.currentSession == nil)

        _ = try await subject.session()
        #expect(provider.totalCalls == 2)
    }

    @Test("concurrent callers acquire once between them")
    func concurrentCallersShareOneAcquisition() async throws {
        let provider = StubCredentialProvider(outcomes: [.success(.testFresh())])
        let subject = refresher(provider: provider)

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<6 {
                group.addTask { try await subject.session().resolvedToken }
            }
            var collected: [String?] = []
            for try await token in group { collected.append(token) }
            return collected
        }

        #expect(tokens.count == 6)
        #expect(Set(tokens.compactMap { $0 }) == ["t"])
        #expect(provider.totalCalls == 1)
    }
}
