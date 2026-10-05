import Foundation
import SiriusXMCore

/// Turns a `CredentialProvider` into something the rest of the app can call
/// from anywhere without thinking about the retry budget.
///
/// Three properties, and all three are load-bearing:
///
///   - **Single-flight.** Concurrent callers share one acquisition. Nobody
///     gets a second sign-in prompt because two requests noticed expiry at the
///     same time.
///   - **Bounded.** At most `RetryPolicy.maximumAuthAttempts` calls into the
///     provider per acquisition cycle, with exponential backoff between them.
///     After that the failure surfaces to a human.
///   - **Cache-aware.** A session that is still fresh is returned without
///     touching the provider at all.
///
/// A final class rather than an actor on purpose: an actor would serialise
/// callers at the door, so each one would acquire in turn and single-flight
/// would never actually collapse anything.
public final class BoundedSessionRefresher: @unchecked Sendable {
    private let provider: any CredentialProvider
    private let policy: RetryPolicy
    private let sleeper: any Sleeper
    private let clock: any WallClock
    private let flight = SingleFlight<SessionMaterial>()

    private let lock = NSLock()
    private var cached: SessionMaterial?
    private var attemptsThisCycle: Int = 0

    public init(
        provider: any CredentialProvider,
        policy: RetryPolicy = .default,
        sleeper: any Sleeper = DispatchSleeper(),
        clock: any WallClock = SystemClock()
    ) {
        self.provider = provider
        self.policy = policy
        self.sleeper = sleeper
        self.clock = clock
    }

    /// The cached session, if there is one. Does not acquire and does not fail.
    public var currentSession: SessionMaterial? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Attempts made against the provider since the last success. Exposed so a
    /// future phase can show "we have stopped trying" instead of silently
    /// going quiet.
    public var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptsThisCycle
    }

    /// Cold start. Collapses with any concurrent `session(after:)`.
    public func session() async throws -> SessionMaterial {
        try await flight.run { [self] in
            if let fresh = freshCachedSession() { return fresh }
            return try await acquire(signal: nil)
        }
    }

    /// Mid-session re-entry after an in-band expiry signal.
    ///
    /// Structurally identical to `session()` on purpose. The app must not carry
    /// two code paths for "I need a session", because only the cold one would
    /// be exercised until the first real expiry.
    public func session(after signal: SessionExpirySignal) async throws -> SessionMaterial {
        try await flight.run { [self] in
            discardCachedSession()
            return try await acquire(signal: signal)
        }
    }

    /// Extend a session that is still good. Never touches the password.
    ///
    /// Falls back to a full re-entry when the provider declines to renew, so a
    /// caller always ends up with something usable or with an error, never
    /// with the same session it started with and no signal that anything went
    /// wrong.
    public func renew(_ session: SessionMaterial) async throws -> SessionMaterial {
        try await flight.run { [self] in
            var renewed: SessionMaterial?
            do {
                renewed = try await provider.refresh(session)
            } catch CredentialError.humanSignInRequired {
                renewed = nil
            }

            if let renewed, renewed.isUsableAndFresh(at: clock.now) {
                store(renewed)
                return renewed
            }
            return try await acquire(signal: .clockExpired(at: clock.now))
        }
    }

    /// Forgets the cached session. Called on sign-out and on an explicit
    /// "start over", never as a way to make a failure go away.
    public func invalidate() {
        discardCachedSession()
    }

    // MARK: - The bounded loop

    private func acquire(signal: SessionExpirySignal?) async throws -> SessionMaterial {
        var lastError: any Error = CredentialError.unavailable(detail: "not-attempted")

        for attempt in 1...max(1, policy.maximumAuthAttempts) {
            recordAttempt()
            do {
                let material: SessionMaterial
                if let signal {
                    material = try await provider.reauthenticate(after: signal)
                } else {
                    material = try await provider.acquire()
                }
                guard material.isUsable else {
                    lastError = CredentialError.unavailable(detail: "provider-returned-empty-session")
                    continue
                }
                store(material)
                return material
            } catch let error as CredentialError {
                lastError = error
                let wait = waitForRateLimit(error, attempt: attempt)
                try await sleeper.sleep(for: wait)
            } catch {
                lastError = CredentialError.unavailable(detail: "provider-threw-unclassified")
                try await sleeper.sleep(for: policy.backoff(afterAttempt: attempt))
            }
        }

        throw normalised(lastError)
    }

    /// A `rateLimited` error carries the server's own instruction, which
    /// outranks the computed backoff. Every other error uses the backoff.
    private func waitForRateLimit(_ error: CredentialError, attempt: Int) -> Duration {
        if case .rateLimited(let seconds) = error, let seconds {
            return policy.delay(afterAttempt: attempt, retryAfterSeconds: seconds)
        }
        return policy.backoff(afterAttempt: attempt)
    }

    /// The budget is the last word: however the loop ended, three attempts is
    /// three attempts.
    private func normalised(_ error: any Error) -> any Error {
        if case CredentialError.retryBudgetExhausted = error { return error }
        return CredentialError.retryBudgetExhausted(attempts: policy.maximumAuthAttempts)
    }

    // MARK: - State

    private func freshCachedSession() -> SessionMaterial? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached else { return nil }
        return cached.isUsableAndFresh(at: clock.now) ? cached : nil
    }

    private func store(_ material: SessionMaterial) {
        lock.lock()
        cached = material
        attemptsThisCycle = 0
        lock.unlock()
    }

    private func discardCachedSession() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private func recordAttempt() {
        lock.lock()
        attemptsThisCycle += 1
        lock.unlock()
    }
}
