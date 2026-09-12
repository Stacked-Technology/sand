import Foundation

struct GitHubRunnerPoolJob: Equatable, Sendable {
    let id: Int64
    let runID: Int64
    let repository: String
}

struct GitHubRunnerPoolSnapshot: Equatable, Sendable {
    let queuedJobs: Int
    let busyRunners: Int
    let onlineRunnerNames: Set<String>
    let capturedAt: Date
    let busyRunnerNames: Set<String>
    let queuedJobDetails: [GitHubRunnerPoolJob]
    let inProgressJobDetails: [GitHubRunnerPoolJob]

    static let maximumJobDetails = 32

    init(
        queuedJobs: Int,
        busyRunners: Int,
        onlineRunnerNames: Set<String>,
        capturedAt: Date,
        busyRunnerNames: Set<String> = [],
        queuedJobDetails: [GitHubRunnerPoolJob] = [],
        inProgressJobDetails: [GitHubRunnerPoolJob] = []
    ) {
        self.queuedJobs = queuedJobs
        self.busyRunners = busyRunners
        self.onlineRunnerNames = onlineRunnerNames
        self.capturedAt = capturedAt
        self.busyRunnerNames = busyRunnerNames
        self.queuedJobDetails = Array(queuedJobDetails.prefix(Self.maximumJobDetails))
        self.inProgressJobDetails = Array(inProgressJobDetails.prefix(Self.maximumJobDetails))
    }
}

enum GitHubRunnerPoolMonitorError: Error, CustomStringConvertible {
    case http(status: Int, body: String, retryAfter: TimeInterval?)

    var retryAfter: TimeInterval? {
        switch self {
        case let .http(_, _, retryAfter):
            return retryAfter
        }
    }

    var status: Int {
        switch self {
        case let .http(status, _, _):
            return status
        }
    }

    var description: String {
        switch self {
        case let .http(status, body, _):
            return "GitHub API HTTP \(status): \(body)"
        }
    }
}

protocol GitHubRunnerPoolMonitoring: Sendable {
    func snapshot() async throws -> GitHubRunnerPoolSnapshot
}

actor GitHubRunnerPoolMonitor: GitHubRunnerPoolMonitoring {
    private struct InstallationResponse: Decodable {
        let id: Int
    }

    private struct AccessTokenResponse: Decodable {
        let token: String
        let expiresAt: String
    }

    private struct WorkflowRunsResponse: Decodable {
        let totalCount: Int
        let workflowRuns: [WorkflowRun]
    }

    private struct WorkflowRun: Decodable {
        let id: Int64
    }

    private struct InstallationRepositoriesResponse: Decodable {
        let totalCount: Int
        let repositories: [InstallationRepository]
    }

    private struct InstallationRepository: Decodable {
        let fullName: String
    }

    private struct WorkflowJobsResponse: Decodable {
        let totalCount: Int
        let jobs: [WorkflowJob]
    }

    private struct WorkflowJob: Decodable {
        let id: Int64
        let status: String
        let labels: [String]
    }

    private struct MatchingJobs {
        var queuedCount = 0
        var queuedDetails: [GitHubRunnerPoolJob] = []
        var inProgressDetails: [GitHubRunnerPoolJob] = []
    }

    private struct RunnersResponse: Decodable {
        let totalCount: Int
        let runners: [RegisteredRunner]
    }

    private struct RegisteredRunner: Decodable {
        let name: String
        let status: String
        let busy: Bool
    }

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private let auth: GitHubAuthenticating
    private let session: URLSessionProtocol
    private let organization: String
    private let repositories: [String]?
    private let excludedRepositories: Set<String>
    private let matchLabels: Set<String>
    private let runnerNames: Set<String>
    private let baseURL = URL(string: "https://api.github.com")!
    private var cachedInstallationID: Int?
    private var cachedToken: CachedToken?
    private var cachedOrganizationRepositories: [String]?
    private var cachedOrganizationRepositoriesAt: Date?

    init(
        auth: GitHubAuthenticating,
        session: URLSessionProtocol,
        organization: String,
        repositories: [String]? = nil,
        matchLabels: [String],
        runnerNames: Set<String>,
        excludedRepositories: [String] = []
    ) {
        self.auth = auth
        self.session = session
        self.organization = organization
        self.repositories = repositories
        self.excludedRepositories = Set(excludedRepositories.map { $0.lowercased() })
        self.matchLabels = Set(matchLabels)
        self.runnerNames = runnerNames
    }

    func snapshot() async throws -> GitHubRunnerPoolSnapshot {
        do {
            return try await snapshotWithCurrentToken()
        } catch let error as GitHubRunnerPoolMonitorError where error.status == 401 {
            cachedToken = nil
            return try await snapshotWithCurrentToken()
        }
    }

    private func snapshotWithCurrentToken() async throws -> GitHubRunnerPoolSnapshot {
        let token = try await installationAccessToken(allowInstallationRefresh: true)
        async let queuedJobs = matchingJobs(token: token)
        async let runnerState = registeredRunnerState(token: token)
        let (queued, state) = try await (queuedJobs, runnerState)
        return GitHubRunnerPoolSnapshot(
            queuedJobs: queued.queuedCount,
            busyRunners: state.busy,
            onlineRunnerNames: state.online,
            capturedAt: Date(),
            busyRunnerNames: state.busyNames,
            queuedJobDetails: queued.queuedDetails,
            inProgressJobDetails: queued.inProgressDetails
        )
    }

    private func installationAccessToken(allowInstallationRefresh: Bool) async throws -> String {
        if let cachedToken, cachedToken.expiresAt.timeIntervalSinceNow > 60 {
            return cachedToken.value
        }
        let installationID: Int
        if let cachedInstallationID {
            installationID = cachedInstallationID
        } else {
            let appToken = try auth.token(now: Date())
            let response: InstallationResponse = try await request(
                path: "/orgs/\(organization)/installation",
                method: "GET",
                token: appToken
            )
            cachedInstallationID = response.id
            installationID = response.id
        }
        let appToken = try auth.token(now: Date())
        let response: AccessTokenResponse
        do {
            var payload: [String: Any] = [
                "permissions": [
                    "actions": "read",
                    "organization_self_hosted_runners": "read"
                ]
            ]
            if let repositories {
                payload["repositories"] = repositories
            }
            let requestBody = try JSONSerialization.data(withJSONObject: payload)
            response = try await request(
                path: "/app/installations/\(installationID)/access_tokens",
                method: "POST",
                token: appToken,
                body: requestBody
            )
        } catch let error as GitHubRunnerPoolMonitorError
            where error.status == 404 && allowInstallationRefresh {
            cachedInstallationID = nil
            return try await installationAccessToken(allowInstallationRefresh: false)
        }
        let formatter = ISO8601DateFormatter()
        guard let expiresAt = formatter.date(from: response.expiresAt) else {
            throw GitHubServiceError.invalidResponse
        }
        cachedToken = CachedToken(value: response.token, expiresAt: expiresAt)
        return response.token
    }

    private func matchingJobs(token: String) async throws -> MatchingJobs {
        let repositories = try await monitoredRepositories(token: token)
        var runIDsByRepository: [String: Set<Int64>] = [:]
        for repository in repositories {
            var runIDs = Set<Int64>()
            for status in ["queued", "in_progress"] {
                var page = 1
                while true {
                    let response: WorkflowRunsResponse = try await request(
                        path: "/repos/\(organization)/\(repository)/actions/runs",
                        method: "GET",
                        token: token,
                        queryItems: [
                            URLQueryItem(name: "status", value: status),
                            URLQueryItem(name: "per_page", value: "100"),
                            URLQueryItem(name: "page", value: String(page))
                        ]
                    )
                    runIDs.formUnion(response.workflowRuns.map(\.id))
                    if page * 100 >= response.totalCount || response.workflowRuns.isEmpty {
                        break
                    }
                    page += 1
                }
            }
            runIDsByRepository[repository] = runIDs
        }

        var matching = MatchingJobs()
        for repository in repositories {
            for runID in runIDsByRepository[repository] ?? [] {
                try await collectMatchingJobs(
                    repository: repository,
                    runID: runID,
                    token: token,
                    into: &matching
                )
            }
        }
        matching.queuedDetails.sort { lhs, rhs in
            lhs.id == rhs.id ? lhs.repository < rhs.repository : lhs.id < rhs.id
        }
        matching.inProgressDetails.sort { lhs, rhs in
            lhs.id == rhs.id ? lhs.repository < rhs.repository : lhs.id < rhs.id
        }
        matching.queuedDetails = Array(matching.queuedDetails.prefix(GitHubRunnerPoolSnapshot.maximumJobDetails))
        matching.inProgressDetails = Array(matching.inProgressDetails.prefix(GitHubRunnerPoolSnapshot.maximumJobDetails))
        return matching
    }

    private func collectMatchingJobs(
        repository: String,
        runID: Int64,
        token: String,
        into matching: inout MatchingJobs
    ) async throws {
        var page = 1
        while true {
            let response: WorkflowJobsResponse = try await request(
                path: "/repos/\(organization)/\(repository)/actions/runs/\(runID)/jobs",
                method: "GET",
                token: token,
                queryItems: [
                    URLQueryItem(name: "filter", value: "latest"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
            for job in response.jobs where matchLabels.isSubset(of: Set(job.labels)) {
                let detail = GitHubRunnerPoolJob(id: job.id, runID: runID, repository: repository)
                switch job.status {
                case "queued":
                    matching.queuedCount += 1
                    if matching.queuedDetails.count < GitHubRunnerPoolSnapshot.maximumJobDetails {
                        matching.queuedDetails.append(detail)
                    }
                case "in_progress":
                    if matching.inProgressDetails.count < GitHubRunnerPoolSnapshot.maximumJobDetails {
                        matching.inProgressDetails.append(detail)
                    }
                default:
                    continue
                }
            }
            if page * 100 >= response.totalCount || response.jobs.isEmpty {
                break
            }
            page += 1
        }
    }

    private func monitoredRepositories(token: String) async throws -> [String] {
        let repositories: [String]
        if let configuredRepositories = self.repositories {
            repositories = configuredRepositories
        } else {
            repositories = try await organizationRepositories(token: token)
        }
        return repositories.filter { !excludedRepositories.contains($0.lowercased()) }
    }

    private func organizationRepositories(token: String) async throws -> [String] {
        if let cachedOrganizationRepositories,
           let cachedAt = cachedOrganizationRepositoriesAt,
           Date().timeIntervalSince(cachedAt) < 60 {
            return cachedOrganizationRepositories
        }

        var repositories = Set<String>()
        var page = 1
        let organizationPrefix = "\(organization.lowercased())/"
        while true {
            let response: InstallationRepositoriesResponse = try await request(
                path: "/installation/repositories",
                method: "GET",
                token: token,
                queryItems: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
            for repository in response.repositories {
                let fullName = repository.fullName
                guard fullName.lowercased().hasPrefix(organizationPrefix) else {
                    continue
                }
                repositories.insert(String(fullName.dropFirst(organizationPrefix.count)))
            }
            if page * 100 >= response.totalCount || response.repositories.isEmpty {
                break
            }
            page += 1
        }

        let resolvedRepositories = repositories.sorted()
        cachedOrganizationRepositories = resolvedRepositories
        cachedOrganizationRepositoriesAt = Date()
        return resolvedRepositories
    }

    private func registeredRunnerState(token: String) async throws -> (
        busy: Int,
        busyNames: Set<String>,
        online: Set<String>
    ) {
        var page = 1
        var busy = 0
        var busyNames = Set<String>()
        var online = Set<String>()
        while true {
            let response: RunnersResponse = try await request(
                path: "/orgs/\(organization)/actions/runners",
                method: "GET",
                token: token,
                queryItems: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
            for runner in response.runners where runnerNames.contains(runner.name) {
                guard runner.status == "online" else {
                    continue
                }
                online.insert(runner.name)
                if runner.busy {
                    busy += 1
                    busyNames.insert(runner.name)
                }
            }
            if page * 100 >= response.totalCount || response.runners.isEmpty {
                break
            }
            page += 1
        }
        return (busy, busyNames, online)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        token: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        guard var components = URLComponents(url: URL(string: path, relativeTo: baseURL)!, resolvingAgainstBaseURL: true) else {
            throw GitHubServiceError.invalidResponse
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw GitHubServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("sand", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(4_096), as: UTF8.self)
            throw GitHubRunnerPoolMonitorError.http(
                status: httpResponse.statusCode,
                body: body,
                retryAfter: retryDelay(from: httpResponse)
            )
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter) {
            return Swift.max(0, seconds)
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let epoch = TimeInterval(reset) {
            return Swift.max(0, epoch - Date().timeIntervalSince1970)
        }
        return nil
    }
}
