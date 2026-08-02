import Foundation

private final class RunnerPoolStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

actor RunnerPoolControl {
    private var shuttingDown = false
    private var slotCancellations: [UUID: @Sendable () -> Void] = [:]
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func beginShutdown() {
        shuttingDown = true
        let waiters = shutdownWaiters
        shutdownWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
        let cancellations = slotCancellations.values
        for cancel in cancellations {
            cancel()
        }
        resumeQuiescenceWaitersIfNeeded()
    }

    func isShuttingDown() -> Bool {
        shuttingDown
    }

    func registerSlot(
        id: UUID,
        cancel: @escaping @Sendable () -> Void
    ) -> Bool {
        guard !shuttingDown else {
            return false
        }
        slotCancellations[id] = cancel
        return true
    }

    func endSlot(id: UUID) {
        slotCancellations[id] = nil
        resumeQuiescenceWaitersIfNeeded()
    }

    func waitForQuiescence() async {
        if slotCancellations.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    func waitForShutdown() async {
        if shuttingDown {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if shuttingDown || Task.isCancelled {
                    continuation.resume()
                    return
                }
                shutdownWaiters[waiterID] = continuation
            }
        }, onCancel: {
            Task { await cancelShutdownWaiter(id: waiterID) }
        })
    }

    private func cancelShutdownWaiter(id: UUID) {
        shutdownWaiters.removeValue(forKey: id)?.resume()
    }

    private func resumeQuiescenceWaitersIfNeeded() {
        guard shuttingDown, slotCancellations.isEmpty else {
            return
        }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension Config.RunnerConfig {
    func poolSlot(index: Int, baseline: Bool) -> Config.RunnerConfig {
        precondition(index >= 1)
        let slotName = index == 1 ? name : "\(name)-\(index)"
        let slotProvisioner: Config.Provisioner
        if let github = provisioner.github {
            slotProvisioner = Config.Provisioner(
                type: provisioner.type,
                script: nil,
                github: github.withRunnerName(
                    index == 1 ? github.runnerName : "\(github.runnerName)-\(index)"
                )
            )
        } else {
            slotProvisioner = provisioner
        }
        return Config.RunnerConfig(
            name: slotName,
            vm: vm,
            provisioner: slotProvisioner,
            preRun: preRun,
            postRun: postRun,
            stopAfter: baseline ? nil : 1,
            healthCheck: healthCheck,
            pool: nil
        )
    }
}

struct RunnerPoolSlot: Sendable {
    let index: Int
    let name: String
    let registrationName: String
    private let runOperation: @Sendable () async throws -> Void

    init(index: Int, name: String, registrationName: String, runner: Runner) {
        self.index = index
        self.name = name
        self.registrationName = registrationName
        self.runOperation = {
            try await runner.run()
        }
    }

    init(
        index: Int,
        name: String,
        registrationName: String,
        run: @escaping @Sendable () async throws -> Void
    ) {
        self.index = index
        self.name = name
        self.registrationName = registrationName
        self.runOperation = run
    }

    func run() async throws {
        try await runOperation()
    }
}

enum RunnerPoolScaler {
    static func desiredRunnerCount(
        minimum: Int,
        maximum: Int,
        busyRunners: Int,
        queuedJobs: Int
    ) -> Int {
        Swift.min(maximum, Swift.max(minimum, busyRunners + queuedJobs))
    }

    static func retryDelay(
        pollInterval: TimeInterval,
        consecutiveFailures: Int,
        retryAfter: TimeInterval?
    ) -> TimeInterval {
        let exponent = Swift.max(0, Swift.min(consecutiveFailures - 1, 6))
        let exponential = Swift.min(300, pollInterval * pow(2, Double(exponent)))
        return Swift.max(exponential, retryAfter ?? 0)
    }
}

struct RunnerPool: Sendable {
    private enum Event: Sendable {
        case runnerFinished(index: Int, errorDescription: String?)
        case snapshot(GitHubRunnerPoolSnapshot)
        case pollFailed(message: String, retryAfter: TimeInterval?)
        case restartBaseline(index: Int)
        case shutdown
    }

    let config: Config.RunnerPool
    let slots: [RunnerPoolSlot]
    let monitor: any GitHubRunnerPoolMonitoring
    let logger: Logger
    let control: RunnerPoolControl
    let baselineRestartDelay: @Sendable (_ consecutiveFailures: Int) -> TimeInterval

    init(
        config: Config.RunnerPool,
        slots: [RunnerPoolSlot],
        monitor: any GitHubRunnerPoolMonitoring,
        logger: Logger,
        control: RunnerPoolControl = RunnerPoolControl(),
        baselineRestartDelay: @escaping @Sendable (_ consecutiveFailures: Int) -> TimeInterval = {
            failures in
            let baseDelay = RunnerPoolScaler.retryDelay(
                pollInterval: 5,
                consecutiveFailures: failures,
                retryAfter: nil
            )
            return baseDelay + Double.random(in: 0...Swift.min(5, baseDelay * 0.2))
        }
    ) {
        self.config = config
        self.slots = slots
        self.monitor = monitor
        self.logger = logger
        self.control = control
        self.baselineRestartDelay = baselineRestartDelay
    }

    func run() async throws {
        precondition(slots.count == config.max)
        var activeIndices = Set<Int>()
        var recentlyFinishedIndices = Set<Int>()
        var pendingBaselineRestarts = Set<Int>()
        var baselineFailures: [Int: Int] = [:]
        var consecutivePollFailures = 0

        try await withThrowingTaskGroup(of: Event.self) { group in
            func startRunner(at index: Int) {
                let slot = slots[index]
                activeIndices.insert(index)
                recentlyFinishedIndices.remove(index)
                logger.info("pool start runner \(slot.name) (slot \(index + 1)/\(config.max))")
                group.addTask {
                    let slotID = UUID()
                    let startGate = RunnerPoolStartGate()
                    let runnerTask = Task {
                        await startGate.wait()
                        do {
                            try Task.checkCancellation()
                            try await slot.run()
                            return Event.runnerFinished(
                                index: index,
                                errorDescription: nil
                            )
                        } catch {
                            return Event.runnerFinished(
                                index: index,
                                errorDescription: String(describing: error)
                            )
                        }
                    }
                    let admitted = await control.registerSlot(
                        id: slotID,
                        cancel: {
                            runnerTask.cancel()
                            startGate.open()
                        }
                    )
                    if !admitted || Task.isCancelled {
                        runnerTask.cancel()
                    }
                    startGate.open()
                    let event = await withTaskCancellationHandler(operation: {
                        await runnerTask.value
                    }, onCancel: {
                        runnerTask.cancel()
                        startGate.open()
                    })
                    if admitted {
                        await control.endSlot(id: slotID)
                    }
                    return event
                }
            }

            func schedulePoll(after delay: TimeInterval) {
                let monitor = monitor
                group.addTask {
                    if delay > 0 {
                        try await Task.sleep(for: .seconds(delay))
                    }
                    do {
                        return .snapshot(try await monitor.snapshot())
                    } catch let error as GitHubRunnerPoolMonitorError {
                        return .pollFailed(
                            message: error.description,
                            retryAfter: error.retryAfter
                        )
                    } catch {
                        return .pollFailed(
                            message: String(describing: error),
                            retryAfter: nil
                        )
                    }
                }
            }

            func scheduleBaselineRestart(at index: Int) {
                let failures = baselineFailures[index, default: 0] + 1
                baselineFailures[index] = failures
                pendingBaselineRestarts.insert(index)
                let delay = baselineRestartDelay(failures)
                logger.warning(
                    "pool baseline runner \(slots[index].name) will restart in " +
                    "\(Int(delay.rounded(.up)))s"
                )
                group.addTask {
                    try await Task.sleep(for: .seconds(delay))
                    return .restartBaseline(index: index)
                }
            }

            for index in 0..<config.min {
                startRunner(at: index)
            }
            group.addTask {
                await control.waitForShutdown()
                return .shutdown
            }
            schedulePoll(after: 0)

            while let event = try await group.next() {
                if await control.isShuttingDown() {
                    group.cancelAll()
                    return
                }
                switch event {
                case let .runnerFinished(index, errorDescription):
                    let slot = slots[index]
                    activeIndices.remove(index)
                    if index < config.min {
                        let message = errorDescription ?? "runner exited unexpectedly"
                        logger.error("pool baseline runner \(slot.name) exited: \(message)")
                        if !(await control.isShuttingDown()) {
                            scheduleBaselineRestart(at: index)
                        }
                        continue
                    }
                    recentlyFinishedIndices.insert(index)
                    if let errorDescription {
                        logger.warning("pool burst runner \(slot.name) exited: \(errorDescription)")
                    } else {
                        logger.info("pool burst runner \(slot.name) completed one job")
                    }

                case let .snapshot(snapshot):
                    consecutivePollFailures = 0
                    recentlyFinishedIndices = Set(recentlyFinishedIndices.filter {
                        snapshot.onlineRunnerNames.contains(slots[$0].registrationName)
                    })
                    for index in 0..<config.min
                        where snapshot.onlineRunnerNames.contains(slots[index].registrationName) {
                        baselineFailures[index] = 0
                    }
                    let recentlyFinishedRunnerNames = Set(
                        recentlyFinishedIndices.map { slots[$0].registrationName }
                    )
                    let registeredIndices = Set(slots.indices.filter {
                        snapshot.onlineRunnerNames.contains(slots[$0].registrationName)
                    })
                    let suppressedFinishedBusyRunners = snapshot.busyRunnerNames
                        .intersection(recentlyFinishedRunnerNames)
                    let effectiveBusyRunners = snapshot.busyRunners - suppressedFinishedBusyRunners.count
                    let occupiedRegistrationIndices = registeredIndices.subtracting(recentlyFinishedIndices)
                    let capacityIndices = activeIndices.union(occupiedRegistrationIndices)
                    let desired = RunnerPoolScaler.desiredRunnerCount(
                        minimum: config.min,
                        maximum: config.max,
                        busyRunners: effectiveBusyRunners,
                        queuedJobs: snapshot.queuedJobs
                    )
                    logger.debug(
                        "pool snapshot queued=\(snapshot.queuedJobs) busy=\(snapshot.busyRunners) " +
                        "effectiveBusy=\(effectiveBusyRunners) active=\(activeIndices.count) " +
                        "registered=\(registeredIndices.count) capacity=\(capacityIndices.count) " +
                        "suppressedBusy=\(suppressedFinishedBusyRunners.sorted()) desired=\(desired)"
                    )

                    if desired > capacityIndices.count {
                        let needed = desired - capacityIndices.count
                        let inactive = slots.indices.filter {
                            !activeIndices.contains($0) &&
                            !occupiedRegistrationIndices.contains($0) &&
                            !pendingBaselineRestarts.contains($0)
                        }
                        for index in inactive.prefix(needed) {
                            startRunner(at: index)
                        }
                    }

                    schedulePoll(after: config.pollInterval)

                case let .pollFailed(message, retryAfter):
                    consecutivePollFailures += 1
                    let baseDelay = RunnerPoolScaler.retryDelay(
                        pollInterval: config.pollInterval,
                        consecutiveFailures: consecutivePollFailures,
                        retryAfter: retryAfter
                    )
                    let jitter = Double.random(in: 0...Swift.min(5, baseDelay * 0.2))
                    let delay = baseDelay + jitter
                    logger.warning(
                        "pool demand poll failed; keeping current capacity and retrying in " +
                        "\(Int(delay.rounded(.up)))s: \(message)"
                    )
                    schedulePoll(after: delay)

                case let .restartBaseline(index):
                    pendingBaselineRestarts.remove(index)
                    if !activeIndices.contains(index) {
                        startRunner(at: index)
                    }

                case .shutdown:
                    group.cancelAll()
                    return
                }
            }
        }
    }
}
