import Foundation
import Testing
@testable import SiriusXMCore
@testable import SiriusXMNet

/// A transport that replays a script and records what it was asked to send.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome: Sendable {
        case response(HTTPResponsePayload)
        case failure(TransportError)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var recorded: [HTTPRequestSpec] = []

    init(_ outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    var sentRequests: [HTTPRequestSpec] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var sendCount: Int { sentRequests.count }

    func send(_ request: HTTPRequestSpec) async throws -> HTTPResponsePayload {
        lock.lock()
        recorded.append(request)
        let next = outcomes.isEmpty ? nil : outcomes.removeFirst()
        lock.unlock()

        guard let next else { throw TransportError.unclassified(code: -2) }
        switch next {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// A sleeper that records what it was asked to wait for and returns at once.
final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var delays: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sleep(for interval: Duration) async throws {
        lock.lock()
        recorded.append(interval)
        lock.unlock()
    }
}

/// A clock that does not move.
struct FixedClock: WallClock {
    let now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }
}

/// A credential provider that replays a script and counts what it was asked.
final class StubCredentialProvider: CredentialProvider, @unchecked Sendable {
    enum Outcome: Sendable {
        case success(SessionMaterial)
        case failure(CredentialError)
    }

    let requiresHumanInteraction: Bool

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var acquireCalls = 0
    private var reauthenticateCalls = 0
    private var refreshCalls = 0
    private var signals: [SessionExpirySignal] = []

    init(outcomes: [Outcome] = [], requiresHumanInteraction: Bool = true) {
        self.outcomes = outcomes
        self.requiresHumanInteraction = requiresHumanInteraction
    }

    var callCounts: (acquire: Int, reauthenticate: Int, refresh: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (acquireCalls, reauthenticateCalls, refreshCalls)
    }

    var totalCalls: Int {
        let counts = callCounts
        return counts.acquire + counts.reauthenticate + counts.refresh
    }

    var recordedSignals: [SessionExpirySignal] {
        lock.lock()
        defer { lock.unlock() }
        return signals
    }

    func acquire() async throws -> SessionMaterial {
        lock.lock()
        acquireCalls += 1
        let next = outcomes.isEmpty ? nil : outcomes.removeFirst()
        lock.unlock()
        guard let next else { throw CredentialError.unavailable(detail: "script-exhausted") }
        return try resolve(next)
    }

    func reauthenticate(after signal: SessionExpirySignal) async throws -> SessionMaterial {
        lock.lock()
        reauthenticateCalls += 1
        signals.append(signal)
        let next = outcomes.isEmpty ? nil : outcomes.removeFirst()
        lock.unlock()
        guard let next else { throw CredentialError.unavailable(detail: "script-exhausted") }
        return try resolve(next)
    }

    func refresh(_ session: SessionMaterial) async throws -> SessionMaterial {
        lock.lock()
        refreshCalls += 1
        let next = outcomes.isEmpty ? nil : outcomes.removeFirst()
        lock.unlock()
        guard let next else { throw CredentialError.unavailable(detail: "script-exhausted") }
        return try resolve(next)
    }

    private func resolve(_ outcome: Outcome) throws -> SessionMaterial {
        switch outcome {
        case .success(let material): return material
        case .failure(let error): throw error
        }
    }
}

extension SessionMaterial {
    /// A usable session that is fresh for an hour, for tests that care about
    /// something other than the values.
    static func testFresh(token: String = "t") -> SessionMaterial {
        SessionMaterial(
            token: token,
            gupID: "g",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600)
        )
    }
}
