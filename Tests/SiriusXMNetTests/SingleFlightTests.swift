import Foundation
import Testing
@testable import SiriusXMNet

@Suite("Single flight")
struct SingleFlightTests {
    @Test("concurrent callers run the operation once and share the value")
    func concurrentCallersShareOneRun() async throws {
        let flight = SingleFlight<Int>()
        let runs = Counter()

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await flight.run {
                        await runs.increment()
                        // Long enough that every task is certainly waiting.
                        try? await Task.sleep(for: .milliseconds(20))
                        return 42
                    }
                }
            }
            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(values.count == 8)
        #expect(Set(values) == [42])
        #expect(await runs.value == 1)
    }

    @Test("a failed operation fails every caller and leaves the flight usable")
    func failureIsSharedAndThenResettable() async throws {
        let flight = SingleFlight<Int>()
        let runs = Counter()

        await #expect(throws: Failure.sentinel) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        _ = try await flight.run {
                            await runs.increment()
                            throw Failure.sentinel
                        }
                    }
                }
                try await group.reduce(into: ()) { _, _ in }
            }
        }

        #expect(await runs.value == 1)

        // The next caller starts a new operation rather than inheriting the
        // failure, which is what makes this safe to retry after a real
        // credential failure.
        let recovered = try await flight.run {
            await runs.increment()
            return 7
        }

        #expect(recovered == 7)
        #expect(await runs.value == 2)
    }

    @Test("a caller arriving after completion starts a new run")
    func sequentialCallersEachRun() async throws {
        let flight = SingleFlight<String>()
        let runs = Counter()

        for index in 0..<3 {
            let value = try await flight.run {
                await runs.increment()
                return "run-\(index)"
            }
            #expect(value == "run-\(index)")
        }

        #expect(await runs.value == 3)
        #expect(flight.isRunning == false)
    }

    @Test("nothing is in flight between runs")
    func flightIsIdleWhenIdle() {
        let flight = SingleFlight<Int>()

        #expect(flight.isRunning == false)
    }

    enum Failure: Error, Equatable {
        case sentinel
    }
}

/// An actor, so the counter is correct under Swift 6 without a lock.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
