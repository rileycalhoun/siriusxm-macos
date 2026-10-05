import Foundation
import Dispatch

/// A source of wall-clock time.
///
/// Injected rather than reached for, because every retry decision that depends
/// on elapsed time has to be testable without waiting for elapsed time.
public protocol WallClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: WallClock {
    public init() {}
    public var now: Date { Date() }
}

/// Somewhere to wait between attempts.
///
/// The seam exists so that tests drive backoff in microseconds and so that a
/// future phase can hand in a clock that is driven by playback state rather
/// than by wall time.
public protocol Sleeper: Sendable {
    func sleep(for interval: Duration) async throws
}

/// A sleeper built on `DispatchSourceTimer`.
///
/// `Timer` is not used anywhere in this app: it schedules work on the run loop
/// it was created on, which means a retry scheduled from a background task
/// either fires on the wrong actor or never fires at all. `DispatchSourceTimer`
/// is bound to a queue rather than to a run loop, so the same value works from
/// a task on any actor and inside any concurrency domain.
public struct DispatchSleeper: Sleeper {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "com.siriusxm.retry", qos: .utility)) {
        self.queue = queue
    }

    public func sleep(for interval: Duration) async throws {
        let nanoseconds = interval.nanoseconds
        guard nanoseconds > 0 else { return }

        let box = CancellationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .nanoseconds(nanoseconds))
                timer.setEventHandler {
                    timer.cancel()
                    box.finish { continuation.resume() }
                }
                box.install { [timer] in
                    timer.cancel()
                    continuation.resume(throwing: CancellationError())
                }
                timer.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// A sleeper that never waits, for tests and for previews.
public struct ImmediateSleeper: Sleeper {
    public init() {}
    public func sleep(for interval: Duration) async throws {
        _ = interval
    }
}

/// Holds the timer so the cancellation handler can cancel it.
///
/// `NSLock` rather than `Synchronization.Mutex`, which is macOS 15 and this
/// package deploys to macOS 14.
private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelWork: (() -> Void)?
    private var isFinished = false

    func install(_ work: @escaping () -> Void) {
        lock.lock()
        if isFinished {
            lock.unlock()
            work()
            return
        }
        cancelWork = work
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let work = cancelWork
        cancelWork = nil
        lock.unlock()
        work?()
    }

    /// Runs `body` at most once, whichever of cancel and finish gets there
    /// first, so a continuation is never resumed twice.
    func finish(_ body: () -> Void) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        cancelWork = nil
        lock.unlock()
        body()
    }
}

extension Duration {
    /// Whole nanoseconds, rounded up so a sub-nanosecond wait is still a wait.
    var nanoseconds: UInt64 {
        let parts = components
        let seconds = parts.seconds < 0 ? 0 : parts.seconds
        let attoseconds = parts.attoseconds < 0 ? 0 : parts.attoseconds
        let total = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        return UInt64(clamping: total)
    }
}
