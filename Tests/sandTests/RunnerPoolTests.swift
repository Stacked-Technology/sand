import XCTest
@testable import sand

private actor ScriptedPoolMonitor: GitHubRunnerPoolMonitoring {
    private let snapshots: [GitHubRunnerPoolSnapshot]
    private var index = 0

    init(snapshots: [GitHubRunnerPoolSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot() async throws -> GitHubRunnerPoolSnapshot {
        let snapshot = snapshots[Swift.min(index, snapshots.count - 1)]
        index += 1
        return snapshot
    }
}

private actor DemandGatedPoolMonitor: GitHubRunnerPoolMonitoring {
    private let initialSnapshot: GitHubRunnerPoolSnapshot
    private let demandSnapshot: GitHubRunnerPoolSnapshot
    private let demandGate: PoolTestGate
    private var snapshotCount = 0

    init(
        initialSnapshot: GitHubRunnerPoolSnapshot,
        demandSnapshot: GitHubRunnerPoolSnapshot,
        demandGate: PoolTestGate
    ) {
        self.initialSnapshot = initialSnapshot
        self.demandSnapshot = demandSnapshot
        self.demandGate = demandGate
    }

    func snapshot() async throws -> GitHubRunnerPoolSnapshot {
        let currentSnapshot = snapshotCount == 0 ? initialSnapshot : demandSnapshot
        snapshotCount += 1
        if snapshotCount > 1 {
            await demandGate.wait()
        }
        return currentSnapshot
    }
}

private actor PoolSlotRecorder {
    private(set) var startedIndices: [Int] = []
    private(set) var cancelledIndices: [Int] = []

    func recordStart(_ index: Int) {
        startedIndices.append(index)
    }

    func recordStartAndCount(_ index: Int) -> Int {
        startedIndices.append(index)
        return startedIndices.filter { $0 == index }.count
    }

    func recordCancellation(_ index: Int) {
        cancelledIndices.append(index)
    }

    func hasStarted(_ index: Int) -> Bool {
        startedIndices.contains(index)
    }

    func startCount(_ index: Int) -> Int {
        startedIndices.filter { $0 == index }.count
    }

    func cancellationCount(_ index: Int) -> Int {
        cancelledIndices.filter { $0 == index }.count
    }
}

private actor PoolTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CleanupRecorder {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}

final class RunnerPoolTests: XCTestCase {
    func testDesiredRunnerCountKeepsWarmMinimumAndHonorsMaximum() {
        XCTAssertEqual(
            RunnerPoolScaler.desiredRunnerCount(
                minimum: 1,
                maximum: 2,
                busyRunners: 0,
                queuedJobs: 0
            ),
            1
        )
        XCTAssertEqual(
            RunnerPoolScaler.desiredRunnerCount(
                minimum: 1,
                maximum: 2,
                busyRunners: 1,
                queuedJobs: 1
            ),
            2
        )
        XCTAssertEqual(
            RunnerPoolScaler.desiredRunnerCount(
                minimum: 1,
                maximum: 2,
                busyRunners: 2,
                queuedJobs: 5
            ),
            2
        )
        XCTAssertEqual(
            RunnerPoolScaler.desiredRunnerCount(
                minimum: 0,
                maximum: 1,
                busyRunners: 0,
                queuedJobs: 0
            ),
            0
        )
        XCTAssertEqual(
            RunnerPoolScaler.desiredRunnerCount(
                minimum: 0,
                maximum: 1,
                busyRunners: 0,
                queuedJobs: 1
            ),
            1
        )
    }

    func testColdStartPoolWaitsForDemandBeforeStartingFirstSlot() async {
        let now = Date()
        let demandGate = PoolTestGate()
        let monitor = DemandGatedPoolMonitor(
            initialSnapshot: GitHubRunnerPoolSnapshot(
                queuedJobs: 0,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: now
            ),
            demandSnapshot: GitHubRunnerPoolSnapshot(
                queuedJobs: 1,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: now.addingTimeInterval(30)
            ),
            demandGate: demandGate
        )
        let recorder = PoolSlotRecorder()
        let pool = makePool(
            monitor: monitor,
            recorder: recorder,
            minimum: 0,
            maximum: 1
        )

        let task = Task {
            try await pool.run()
        }
        try? await Task.sleep(for: .milliseconds(50))
        let startedBeforeDemand = await recorder.hasStarted(0)
        XCTAssertFalse(startedBeforeDemand)

        await demandGate.open()
        let didStartOnDemand = await waitUntil {
            await recorder.hasStarted(0)
        }
        XCTAssertTrue(didStartOnDemand)
        task.cancel()
        _ = try? await task.value
    }

    func testColdStartBurstSlotIsCancelledOnShutdown() async {
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 1,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: Date()
            )
        ])
        let recorder = PoolSlotRecorder()
        let control = RunnerPoolControl()
        let pool = makePool(
            monitor: monitor,
            recorder: recorder,
            minimum: 0,
            maximum: 1,
            control: control
        )

        let task = Task {
            try await pool.run()
        }
        let didStartBurst = await waitUntil {
            await recorder.hasStarted(0)
        }
        XCTAssertTrue(didStartBurst)

        await control.beginShutdown()
        _ = try? await task.value
        await control.waitForQuiescence()

        let cancellationCount = await recorder.cancellationCount(0)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testPoolSlotsUseUniqueNamesAndOneJobBurstLifecycle() throws {
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: nil,
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-pool",
            ephemeral: true,
            extraLabels: ["macos-pool"]
        )
        let template = Config.RunnerConfig(
            name: "runner-pool",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil,
            pool: Config.RunnerPool(
                max: 2,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )

        let baseline = template.poolSlot(index: 1, baseline: true)
        let burst = template.poolSlot(index: 2, baseline: false)
        XCTAssertEqual(baseline.name, "runner-pool")
        XCTAssertEqual(baseline.provisioner.github?.runnerName, "runner-pool")
        XCTAssertNil(baseline.stopAfter)
        XCTAssertNil(baseline.pool)
        XCTAssertEqual(burst.name, "runner-pool-2")
        XCTAssertEqual(burst.provisioner.github?.runnerName, "runner-pool-2")
        XCTAssertEqual(burst.stopAfter, 1)
        XCTAssertNil(burst.pool)
        XCTAssertEqual(burst.provisioner.github?.ephemeral, true)
    }

    func testPoolStartsSecondSlotWhenWarmRunnerIsBusyAndAJobIsQueued() async {
        let now = Date()
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 1,
                busyRunners: 1,
                onlineRunnerNames: ["runner-pool"],
                capturedAt: now
            )
        ])
        let recorder = PoolSlotRecorder()
        let pool = makePool(
            monitor: monitor,
            recorder: recorder
        )

        let task = Task {
            try await pool.run()
        }
        let didStartBurst = await waitUntil {
            await recorder.hasStarted(1)
        }
        XCTAssertTrue(didStartBurst)
        task.cancel()
        _ = try? await task.value
    }

    func testPoolLeavesBurstSlotAvailableWhenQueuedDemandDisappears() async {
        let now = Date()
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 1,
                busyRunners: 1,
                onlineRunnerNames: ["runner-pool"],
                capturedAt: now
            ),
            GitHubRunnerPoolSnapshot(
                queuedJobs: 0,
                busyRunners: 0,
                onlineRunnerNames: ["runner-pool", "runner-pool-2"],
                capturedAt: now.addingTimeInterval(30)
            )
        ])
        let recorder = PoolSlotRecorder()
        let pool = makePool(
            monitor: monitor,
            recorder: recorder
        )

        let task = Task {
            try await pool.run()
        }
        let didStartBurst = await waitUntil {
            await recorder.hasStarted(1)
        }
        XCTAssertTrue(didStartBurst)
        try? await Task.sleep(for: .milliseconds(50))
        let startCount = await recorder.startCount(1)
        XCTAssertEqual(startCount, 1)
        task.cancel()
        _ = try? await task.value
    }

    private func makePool(
        monitor: any GitHubRunnerPoolMonitoring,
        recorder: PoolSlotRecorder,
        minimum: Int = 1,
        maximum: Int = 2,
        control: RunnerPoolControl = RunnerPoolControl()
    ) -> RunnerPool {
        let slots = (0..<maximum).map { index in
            RunnerPoolSlot(
                index: index,
                name: index == 0 ? "runner-pool" : "runner-pool-\(index + 1)",
                registrationName: index == 0 ? "runner-pool" : "runner-pool-\(index + 1)",
                run: {
                    await recorder.recordStart(index)
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await recorder.recordCancellation(index)
                        throw error
                    }
                }
            )
        }
        return RunnerPool(
            config: Config.RunnerPool(
                min: minimum,
                max: maximum,
                pollInterval: 0.01,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            ),
            slots: slots,
            monitor: monitor,
            logger: Logger(label: "pool.test", minimumLevel: .error),
            control: control
        )
    }

    func testRetryDelayUsesExponentialBackoffAndHonorsServerMinimum() {
        XCTAssertEqual(
            RunnerPoolScaler.retryDelay(
                pollInterval: 30,
                consecutiveFailures: 1,
                retryAfter: nil
            ),
            30
        )
        XCTAssertEqual(
            RunnerPoolScaler.retryDelay(
                pollInterval: 30,
                consecutiveFailures: 4,
                retryAfter: nil
            ),
            240
        )
        XCTAssertEqual(
            RunnerPoolScaler.retryDelay(
                pollInterval: 30,
                consecutiveFailures: 10,
                retryAfter: 600
            ),
            600
        )
    }

    func testBaselineFailureDoesNotCancelBurstRunner() async {
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 1,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: Date()
            )
        ])
        let recorder = PoolSlotRecorder()
        let slots = [
            RunnerPoolSlot(
                index: 0,
                name: "runner-pool",
                registrationName: "runner-pool",
                run: {
                    let attempt = await recorder.recordStartAndCount(0)
                    if attempt == 1 {
                        throw NSError(domain: "test", code: 1)
                    }
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await recorder.recordCancellation(0)
                        throw error
                    }
                }
            ),
            RunnerPoolSlot(
                index: 1,
                name: "runner-pool-2",
                registrationName: "runner-pool-2",
                run: {
                    await recorder.recordStart(1)
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await recorder.recordCancellation(1)
                        throw error
                    }
                }
            )
        ]
        let pool = RunnerPool(
            config: Config.RunnerPool(
                min: 1,
                max: 2,
                pollInterval: 0.01,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            ),
            slots: slots,
            monitor: monitor,
            logger: Logger(label: "pool.test", minimumLevel: .error),
            baselineRestartDelay: { _ in 0.1 }
        )

        let task = Task {
            try await pool.run()
        }
        let recoveredWithoutCancelingBurst = await waitUntil {
            let burstStarted = await recorder.hasStarted(1)
            let baselineStarts = await recorder.startCount(0)
            return burstStarted && baselineStarts >= 2
        }
        XCTAssertTrue(recoveredWithoutCancelingBurst)
        let burstCancellations = await recorder.cancellationCount(1)
        XCTAssertEqual(burstCancellations, 0)
        task.cancel()
        _ = try? await task.value
    }

    func testShutdownPreventsScheduledBaselineRestart() async {
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 0,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: Date()
            )
        ])
        let recorder = PoolSlotRecorder()
        let control = RunnerPoolControl()
        let slots = [
            RunnerPoolSlot(
                index: 0,
                name: "runner-pool",
                registrationName: "runner-pool",
                run: {
                    await recorder.recordStart(0)
                    throw NSError(domain: "test", code: 1)
                }
            ),
            RunnerPoolSlot(
                index: 1,
                name: "runner-pool-2",
                registrationName: "runner-pool-2",
                run: {
                    await recorder.recordStart(1)
                    try await Task.sleep(for: .seconds(60))
                }
            )
        ]
        let pool = RunnerPool(
            config: Config.RunnerPool(
                min: 1,
                max: 2,
                pollInterval: 0.01,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            ),
            slots: slots,
            monitor: monitor,
            logger: Logger(label: "pool.test", minimumLevel: .error),
            control: control,
            baselineRestartDelay: { _ in 0.1 }
        )

        let task = Task {
            try await pool.run()
        }
        let firstFailureObserved = await waitUntil {
            await recorder.startCount(0) == 1
        }
        XCTAssertTrue(firstFailureObserved)
        await control.beginShutdown()
        _ = try? await task.value
        try? await Task.sleep(for: .milliseconds(150))
        let baselineStarts = await recorder.startCount(0)
        XCTAssertEqual(baselineStarts, 1)
    }

    func testShutdownAtomicallyRejectsLateSlotStart() async {
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 0,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: Date()
            )
        ])
        let recorder = PoolSlotRecorder()
        let control = RunnerPoolControl()
        await control.beginShutdown()
        let pool = RunnerPool(
            config: Config.RunnerPool(
                min: 1,
                max: 1,
                pollInterval: 0.01,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            ),
            slots: [
                RunnerPoolSlot(
                    index: 0,
                    name: "runner-pool",
                    registrationName: "runner-pool",
                    run: {
                        await recorder.recordStart(0)
                    }
                )
            ],
            monitor: monitor,
            logger: Logger(label: "pool.test", minimumLevel: .error),
            control: control
        )

        _ = try? await pool.run()

        let starts = await recorder.startCount(0)
        XCTAssertEqual(starts, 0)
        await control.waitForQuiescence()
    }

    func testShutdownCancelsSlotAdmittedBeforeCleanup() async {
        let monitor = ScriptedPoolMonitor(snapshots: [
            GitHubRunnerPoolSnapshot(
                queuedJobs: 0,
                busyRunners: 0,
                onlineRunnerNames: [],
                capturedAt: Date()
            )
        ])
        let recorder = PoolSlotRecorder()
        let gate = PoolTestGate()
        let control = RunnerPoolControl()
        let pool = RunnerPool(
            config: Config.RunnerPool(
                min: 1,
                max: 1,
                pollInterval: 0.01,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            ),
            slots: [
                RunnerPoolSlot(
                    index: 0,
                    name: "runner-pool",
                    registrationName: "runner-pool",
                    run: {
                        await recorder.recordStart(0)
                        await gate.wait()
                        try Task.checkCancellation()
                        await recorder.recordStart(99)
                    }
                )
            ],
            monitor: monitor,
            logger: Logger(label: "pool.test", minimumLevel: .error),
            control: control
        )

        let task = Task {
            try await pool.run()
        }
        let admitted = await waitUntil {
            await recorder.hasStarted(0)
        }
        XCTAssertTrue(admitted)
        await control.beginShutdown()
        await gate.open()
        _ = try? await task.value
        await control.waitForQuiescence()

        let passedCancellationCheckpoint = await recorder.hasStarted(99)
        XCTAssertFalse(passedCancellationCheckpoint)
    }

    func testCancellationResistantCleanupCompletesFromCancelledTask() async {
        let recorder = CleanupRecorder()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            await CancellationResistantCleanup.run {
                try? await Task.sleep(for: .milliseconds(10))
                await recorder.markCompleted()
            }
        }

        task.cancel()
        await task.value

        let completed = await recorder.completed
        XCTAssertTrue(completed)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
