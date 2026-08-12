import ArgumentParser
import Darwin
import Foundation

@main
@available(macOS 15.0, *)
struct Sand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [Run.self, Destroy.self, Doctor.self, Validate.self, PoolCheck.self]
    )
}

@available(macOS 15.0, *)
struct Run: AsyncParsableCommand {
    @Option(name: .shortAndLong)
    var config: String = Config.defaultPath
    @OptionGroup
    var logLevel: LogLevelOptions
    @Flag(name: .long, help: "Validate configuration and prepare VM images without booting.")
    var dryRun: Bool = false

    mutating func run() async throws {
        let level = logLevel.resolvedLevel()
        let logSink = try logLevel.makeLogFileSink()
        let logger = Logger(label: "sand", minimumLevel: level, sink: logSink)
        logger.info("=== sand run start ===")
        let config = try Config.load(path: config)
        let usesSoftnet = config.runners.contains { $0.vm.run.network == .softnet }
        var requiredDependencies = dryRun ? ["tart"] : ["tart", "sshpass", "ssh"]
        if usesSoftnet, !dryRun {
            requiredDependencies.append("softnet")
        }
        let missing = DependencyChecker.missingCommands(requiredDependencies)
        if !missing.isEmpty {
            throw ValidationError("Missing required dependencies in PATH: \(missing.joined(separator: ", ")). Install them and re-run.")
        }
        if usesSoftnet, !dryRun, !DependencyChecker.softnetPrivilegesAreConfigured() {
            throw ValidationError(
                "Softnet requires root SUID ownership or passwordless sudo before non-interactive use. Complete Softnet's privilege setup and re-run."
            )
        }
        let validator = ConfigValidator()
        let issues = validator.validate(config)
        let errors = issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: " ")
            throw ValidationError("Config validation failed: \(message)")
        }
        for warning in issues where warning.severity == .warning {
            logger.warning("\(warning.message)")
        }
        let processRunner = SystemProcessRunner()
        if dryRun {
            for (index, runnerConfig) in config.runners.enumerated() {
                let runnerIndex = index + 1
                let runnerName = runnerConfig.name
                let logLabel = runnerName.isEmpty ? "runner\(runnerIndex)" : runnerName
                let tart = Tart(processRunner: processRunner, logger: Logger(label: "tart.\(logLabel)", minimumLevel: level, sink: logSink))
                let source = runnerConfig.vm.source.resolvedSource
                logger.info("dry-run: prepare source \(source) for \(logLabel)")
                try await tart.prepare(source: source)
            }
            logger.info("dry-run complete")
            return
        }

        let provisioner = GitHubProvisioner()
        let runnerVersionResolver = GitHubRunnerVersionResolver()
        var runners: [Runner] = []
        var pools: [RunnerPool] = []
        var cleanupTargets: [VMShutdownCoordinator] = []
        var runnerControls: [RunnerControl] = []
        var poolControls: [RunnerPoolControl] = []
        var runtimeIndex = 0

        func makeSlot(_ runnerConfig: Config.RunnerConfig) throws -> (runner: Runner, slot: RunnerPoolSlot) {
            runtimeIndex += 1
            let runnerIndex = runtimeIndex
            let runnerName = runnerConfig.name
            let logLabel = runnerName.isEmpty ? "runner\(runnerIndex)" : runnerName
            let tart = Tart(processRunner: processRunner, logger: Logger(label: "tart.\(logLabel)", minimumLevel: level, sink: logSink))
            let shutdownLogger = Logger(label: "sand.shutdown.\(runnerIndex)", minimumLevel: level, sink: logSink)
            let destroyer = VMDestroyer(tart: tart, logger: shutdownLogger)
            let shutdownCoordinator = VMShutdownCoordinator(destroyer: destroyer, logger: shutdownLogger)
            let runnerControl = RunnerControl()
            cleanupTargets.append(shutdownCoordinator)
            runnerControls.append(runnerControl)
            let github = try githubService(for: runnerConfig.provisioner)
            let runner = Runner(
                tart: tart,
                github: github,
                provisioner: provisioner,
                runnerVersionResolver: runnerVersionResolver,
                config: runnerConfig,
                shutdownCoordinator: shutdownCoordinator,
                control: runnerControl,
                vmName: runnerName,
                logLabel: logLabel,
                logLevel: level,
                logSink: logSink
            )
            return (
                runner,
                RunnerPoolSlot(
                    index: runnerIndex - 1,
                    name: runnerName,
                    registrationName: runnerConfig.provisioner.github?.runnerName ?? runnerName,
                    runner: runner
                )
            )
        }

        for runnerConfig in config.runners {
            guard let poolConfig = runnerConfig.pool else {
                runners.append(try makeSlot(runnerConfig).runner)
                continue
            }
            guard let githubConfig = runnerConfig.provisioner.github else {
                throw ValidationError("Runner pool \(runnerConfig.name) requires a GitHub provisioner.")
            }
            var poolSlots: [RunnerPoolSlot] = []
            var poolRunnerNames = Set<String>()
            for slotOffset in 0..<poolConfig.max {
                let slotConfig = runnerConfig.poolSlot(
                    index: slotOffset + 1,
                    baseline: slotOffset < poolConfig.min
                )
                let components = try makeSlot(slotConfig)
                if let registrationName = slotConfig.provisioner.github?.runnerName {
                    poolRunnerNames.insert(registrationName)
                }
                poolSlots.append(
                    RunnerPoolSlot(
                        index: slotOffset,
                        name: slotConfig.name,
                        registrationName: slotConfig.provisioner.github?.runnerName ?? slotConfig.name,
                        run: {
                            try await components.runner.run()
                        }
                    )
                )
            }
            let auth = try GitHubAuth(
                appId: githubConfig.appId,
                privateKeyPath: githubConfig.privateKeyPath
            )
            let configuredRepositories: [String]? = poolConfig.repositoryScope == .organization
                ? nil
                : poolConfig.repositories
            let monitor = GitHubRunnerPoolMonitor(
                auth: auth,
                session: URLSession.shared,
                organization: githubConfig.organization,
                repositories: configuredRepositories,
                matchLabels: poolConfig.matchLabels,
                runnerNames: poolRunnerNames,
                excludedRepositories: poolConfig.excludeRepositories
            )
            let poolControl = RunnerPoolControl()
            poolControls.append(poolControl)
            pools.append(
                RunnerPool(
                    config: poolConfig,
                    slots: poolSlots,
                    monitor: monitor,
                    logger: Logger(
                        label: "pool.\(runnerConfig.name)",
                        minimumLevel: level,
                        sink: logSink
                    ),
                    control: poolControl
                )
            )
        }
        let shutdownLogger = Logger(label: "sand.shutdown", minimumLevel: level, sink: logSink)
        let signalHandler = SignalHandler(signals: [SIGINT, SIGTERM], logger: shutdownLogger) {
            let group = DispatchGroup()
            for control in poolControls {
                group.enter()
                Task {
                    await control.beginShutdown()
                    group.leave()
                }
            }
            group.wait()
            for control in runnerControls {
                group.enter()
                Task {
                    await control.terminateProvisioning()
                    await control.cancelHealthCheck()
                    group.leave()
                }
            }
            for coordinator in cleanupTargets {
                group.enter()
                Task {
                    await coordinator.cleanup(reason: "signal shutdown")
                    group.leave()
                }
            }
            group.wait()
            for control in poolControls {
                group.enter()
                Task {
                    await control.waitForQuiescence()
                    group.leave()
                }
            }
            group.wait()
        }
        defer {
            _ = signalHandler
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for runner in runners {
                group.addTask {
                    try await runner.run()
                }
            }
            for pool in pools {
                group.addTask {
                    try await pool.run()
                }
            }
            try await group.waitForAll()
        }
    }

    private func githubService(for provisioner: Config.Provisioner?) throws -> GitHubService? {
        guard let provisioner, provisioner.type == .github, let githubConfig = provisioner.github else {
            return nil
        }
        let auth = try GitHubAuth(appId: githubConfig.appId, privateKeyPath: githubConfig.privateKeyPath)
        return GitHubService(
            auth: auth,
            session: URLSession.shared,
            organization: githubConfig.organization,
            repository: githubConfig.repository
        )
    }
}
