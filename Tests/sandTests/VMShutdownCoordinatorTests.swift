import XCTest
@testable import sand

private actor TerminationState {
    private(set) var terminated = false

    func markTerminated() {
        terminated = true
    }
}

private actor CleanupGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CompletionState {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}

final class VMShutdownCoordinatorTests: XCTestCase {
    func testConcurrentCleanupCallerJoinsInFlightCleanup() async {
        let gate = CleanupGate()
        let coordinator = VMShutdownCoordinator(
            destroy: { _ in
                await gate.wait()
            },
            logger: Logger(label: "shutdown.test", minimumLevel: .info)
        )
        await coordinator.activate(name: "ephemeral")
        let first = Task {
            await coordinator.cleanup(reason: "runner")
        }
        for _ in 0 ..< 20 {
            if await gate.hasStarted() {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let destroyStarted = await gate.hasStarted()
        XCTAssertTrue(destroyStarted)

        let completion = CompletionState()
        let second = Task {
            await coordinator.cleanup(reason: "signal")
            await completion.markCompleted()
        }
        try? await Task.sleep(for: .milliseconds(20))
        let completedBeforeRelease = await completion.completed
        XCTAssertFalse(completedBeforeRelease)
        await gate.release()
        await first.value
        await second.value
    }

    func testLateRunHandleIsTerminatedAfterCleanup() async {
        let state = TerminationState()
        let coordinator = VMShutdownCoordinator(
            destroy: { _ in },
            logger: Logger(label: "shutdown.test", minimumLevel: .info)
        )
        let handle = ProcessHandle(
            waitAsync: {
                ProcessResult(stdout: "", stderr: "", exitCode: 0)
            },
            terminate: {
                Task {
                    await state.markTerminated()
                }
            }
        )

        await coordinator.activate(name: "ephemeral")
        await coordinator.cleanup(reason: "test")
        await coordinator.setRunHandle(handle)

        for _ in 0 ..< 20 {
            if await state.terminated {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Late VM run handle was not terminated")
    }
}
