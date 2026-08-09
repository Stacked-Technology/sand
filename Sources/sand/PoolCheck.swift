import ArgumentParser
import Foundation

@available(macOS 15.0, *)
struct PoolCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool-check",
        abstract: "Verify live GitHub API access for configured runner pools."
    )

    @Option(name: .shortAndLong)
    var config: String = Config.defaultPath

    mutating func run() async throws {
        let expandedPath = Config.expandPath(config)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ValidationError("Config file not found at \(expandedPath).")
        }
        let loaded: Config
        do {
            loaded = try Config.load(path: expandedPath)
        } catch {
            throw ValidationError(
                "Failed to load config at \(expandedPath): \(error.localizedDescription)"
            )
        }

        let issues = ConfigValidator().validate(loaded)
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw ValidationError(
                "Config validation failed: \(errors.map(\.message).joined(separator: " "))"
            )
        }

        let pooledRunners = loaded.runners.filter { $0.pool != nil }
        guard !pooledRunners.isEmpty else {
            throw ValidationError("Config has no runner pools to check.")
        }

        for runner in pooledRunners {
            guard let pool = runner.pool, let github = runner.provisioner.github else {
                throw ValidationError(
                    "Runner pool \(runner.name) requires a GitHub provisioner."
                )
            }
            let runnerNames = Set((1...pool.max).compactMap { index in
                runner.poolSlot(index: index, baseline: index <= pool.min)
                    .provisioner.github?.runnerName
            })
            let auth = try GitHubAuth(
                appId: github.appId,
                privateKeyPath: github.privateKeyPath
            )
            let githubService = GitHubService(
                auth: auth,
                session: URLSession.shared,
                organization: github.organization,
                repository: nil
            )
            let configuredRepositories: [String]? = pool.repositoryScope == .organization
                ? nil
                : pool.repositories
            try await Self.verifyRegistrationAccess(
                poolName: runner.name,
                registrationToken: {
                    try await githubService.runnerRegistrationToken(
                        installationRepositories: configuredRepositories,
                        installationPermissions: [
                            "organization_self_hosted_runners": "write"
                        ]
                    )
                }
            )
            let monitor = GitHubRunnerPoolMonitor(
                auth: auth,
                session: URLSession.shared,
                organization: github.organization,
                repositories: configuredRepositories,
                matchLabels: pool.matchLabels,
                runnerNames: runnerNames,
                excludedRepositories: pool.excludeRepositories
            )
            let snapshot = try await Self.verifySnapshot(
                poolName: runner.name,
                monitor: monitor
            )
            let online = snapshot.onlineRunnerNames.sorted().joined(separator: ", ")
            print(
                "Pool \(runner.name) GitHub preflight succeeded: " +
                    "queued=\(snapshot.queuedJobs), busy=\(snapshot.busyRunners), " +
                    "online=[\(online)]."
            )
        }
    }

    static func verifySnapshot(
        poolName: String,
        monitor: any GitHubRunnerPoolMonitoring
    ) async throws -> GitHubRunnerPoolSnapshot {
        do {
            return try await monitor.snapshot()
        } catch let error as GitHubRunnerPoolMonitorError
            where [403, 404, 422].contains(error.status) {
            throw ValidationError(
                "Runner pool \(poolName) GitHub preflight failed. " +
                    "Grant the GitHub App repository permission Actions: Read-only, " +
                    "organization permission Self-hosted runners: Read and write, " +
                    "select every configured repository or enable organization-wide " +
                    "installation access, and accept the updated " +
                    "installation permissions. GitHub returned HTTP \(error.status)."
            )
        }
    }

    static func verifyRegistrationAccess(
        poolName: String,
        registrationToken: @Sendable () async throws -> String
    ) async throws {
        do {
            _ = try await registrationToken()
        } catch let GitHubServiceError.httpError(status, _)
            where [403, 404, 422].contains(status) {
            throw ValidationError(
                "Runner pool \(poolName) registration preflight failed. " +
                    "Grant the GitHub App organization permission " +
                    "Self-hosted runners: Read and write, select every configured " +
                    "repository or enable organization-wide installation access, " +
                    "and accept the updated installation permissions. " +
                    "GitHub returned HTTP \(status)."
            )
        }
    }
}
