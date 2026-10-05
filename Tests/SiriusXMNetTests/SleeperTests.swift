import Foundation
import Testing
@testable import SiriusXMNet

@Suite("Sleeping")
struct SleeperTests {
    @Test("a zero interval does not wait")
    func zeroIntervalReturnsImmediately() async throws {
        let sleeper = DispatchSleeper()
        let started = Date()

        try await sleeper.sleep(for: .zero)

        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("the dispatch sleeper waits roughly as long as it is asked to")
    func dispatchSleeperWaits() async throws {
        let sleeper = DispatchSleeper()
        let started = Date()

        try await sleeper.sleep(for: .milliseconds(40))

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.03)
        #expect(elapsed < 5)
    }

    @Test("cancelling a sleep throws instead of waiting out the interval")
    func cancellationEndsTheSleep() async throws {
        let sleeper = DispatchSleeper()
        let started = Date()

        let task = Task {
            try await sleeper.sleep(for: .seconds(30))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("the immediate sleeper returns without waiting")
    func immediateSleeperDoesNotWait() async throws {
        let sleeper = ImmediateSleeper()
        let started = Date()

        try await sleeper.sleep(for: .seconds(30))

        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("durations convert to whole nanoseconds without overflowing")
    func durationNanoseconds() {
        #expect(Duration.zero.nanoseconds == 0)
        #expect(Duration.milliseconds(1).nanoseconds == 1_000_000)
        #expect(Duration.seconds(2).nanoseconds == 2_000_000_000)
    }
}
