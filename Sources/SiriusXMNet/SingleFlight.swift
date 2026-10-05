import Foundation

/// Collapses concurrent calls into one.
///
/// Used for token refresh. SiriusXM signals expiry in-band, so three
/// concurrent requests can discover an expired session at the same moment, and
/// three simultaneous sign-in attempts are three times the traffic the account
/// is being asked to absorb for one session. Single-flight is what makes "one
/// session, one refresh" true regardless of how many callers notice at once.
///
/// `NSLock`, not `Synchronization.Mutex`: that type is macOS 15 and this
/// package deploys to macOS 14.
public final class SingleFlight<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Task<Value, any Error>?
    private var currentGeneration: UInt64 = 0
    private var nextGeneration: UInt64 = 0

    public init() {}

    /// Number of operations currently in flight. Read-only, for tests and for
    /// the debug overlay.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current != nil
    }

    /// Runs `operation`, or joins the one already running.
    ///
    /// Every caller of the same generation receives the same value or the same
    /// error. A caller that arrives after the operation finished starts a new
    /// one, which is the correct behaviour for a refresh that must happen
    /// again the next time a session expires.
    public func run(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        lock.lock()
        if let existing = current {
            lock.unlock()
            return try await existing.value
        }
        nextGeneration += 1
        let generation = nextGeneration
        let task = Task<Value, any Error> { try await operation() }
        current = task
        lock.unlock()

        do {
            let value = try await task.value
            clear(generation)
            return value
        } catch {
            clear(generation)
            throw error
        }
    }

    private func clear(_ generation: UInt64) {
        lock.lock()
        if currentGeneration == generation {
            current = nil
        }
        lock.unlock()
    }
}
