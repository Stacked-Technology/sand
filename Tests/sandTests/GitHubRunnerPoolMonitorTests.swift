import Foundation
import XCTest
@testable import sand

final class PoolMonitorSession: URLSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            storedRequests.append(request)
        }
        let path = request.url?.path ?? ""
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let status = query.first { $0.name == "status" }?.value
        let body: String
        switch path {
        case "/orgs/acme/installation":
            body = #"{"id":1}"#
        case "/app/installations/1/access_tokens":
            body = #"{"token":"installation-token","expires_at":"2099-01-01T00:00:00Z"}"#
        case "/installation/repositories":
            body = #"{"total_count":3,"repositories":[{"full_name":"acme/mobile"},{"full_name":"acme/legacy"},{"full_name":"other-org/ignored"}]}"#
        case "/repos/acme/mobile/actions/runs" where status == "queued":
            body = #"{"total_count":1,"workflow_runs":[{"id":10}]}"#
        case "/repos/acme/mobile/actions/runs" where status == "in_progress":
            body = #"{"total_count":2,"workflow_runs":[{"id":11},{"id":10}]}"#
        case "/repos/acme/mobile/actions/runs/10/jobs":
            body = """
            {
              "total_count": 2,
              "jobs": [
                {"id": 100, "status": "queued", "labels": ["self-hosted", "macos-pool", "release"]},
                {"id": 101, "status": "queued", "labels": ["self-hosted", "other-pool"]}
              ]
            }
            """
        case "/repos/acme/mobile/actions/runs/11/jobs":
            body = """
            {
              "total_count": 1,
              "jobs": [
                {"id": 102, "status": "in_progress", "labels": ["self-hosted", "macos-pool", "release"]}
              ]
            }
            """
        case "/orgs/acme/actions/runners":
            body = """
            {
              "total_count": 4,
              "runners": [
                {"name": "runner-pool", "status": "online", "busy": true},
                {"name": "runner-pool-2", "status": "online", "busy": false},
                {"name": "runner-pool-old", "status": "online", "busy": false},
                {"name": "another-runner", "status": "online", "busy": true}
              ]
            }
            """
        default:
            throw NSError(
                domain: "PoolMonitorSession",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unexpected request \(request.url?.absoluteString ?? "")"]
            )
        }
        let url = request.url ?? URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class PoolMonitorRecoverySession: URLSessionProtocol, @unchecked Sendable {
    enum Mode {
        case expiredToken
        case staleInstallation
        case rateLimited
    }

    private let lock = NSLock()
    private let mode: Mode
    private var tokenCount = 0
    private var installationCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    var issuedTokenCount: Int {
        lock.withLock { tokenCount }
    }

    var resolvedInstallationCount: Int {
        lock.withLock { installationCount }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        var status = 200
        var headers: [String: String] = [:]
        let body: String = lock.withLock {
            switch path {
            case "/orgs/acme/installation":
                installationCount += 1
                return #"{"id":\#(mode == .staleInstallation && installationCount == 1 ? 1 : 2)}"#
            case "/app/installations/1/access_tokens" where mode == .staleInstallation:
                status = 404
                return #"{"message":"installation not found"}"#
            case "/app/installations/1/access_tokens", "/app/installations/2/access_tokens":
                tokenCount += 1
                return #"{"token":"token-\#(tokenCount)","expires_at":"2099-01-01T00:00:00Z"}"#
            default:
                if mode == .rateLimited {
                    status = 429
                    headers["Retry-After"] = "120"
                    return #"{"message":"slow down"}"#
                }
                if mode == .expiredToken,
                   request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" {
                    status = 401
                    return #"{"message":"expired"}"#
                }
                if path == "/orgs/acme/actions/runners" {
                    return #"{"total_count":0,"runners":[]}"#
                }
                return #"{"total_count":0,"workflow_runs":[]}"#
            }
        }
        let url = request.url ?? URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (Data(body.utf8), response)
    }
}

final class GitHubRunnerPoolMonitorTests: XCTestCase {
    func testSnapshotMatchesQueuedLabelsAndPoolRunnerNames() async throws {
        let session = PoolMonitorSession()
        let monitor = GitHubRunnerPoolMonitor(
            auth: MockAuth(),
            session: session,
            organization: "acme",
            repositories: ["mobile"],
            matchLabels: ["macos-pool", "release"],
            runnerNames: ["runner-pool", "runner-pool-2"]
        )

        let snapshot = try await monitor.snapshot()
        XCTAssertEqual(snapshot.queuedJobs, 1)
        XCTAssertEqual(snapshot.busyRunners, 1)
        XCTAssertEqual(snapshot.busyRunnerNames, Set(["runner-pool"]))
        XCTAssertEqual(
            snapshot.onlineRunnerNames,
            Set(["runner-pool", "runner-pool-2"])
        )

        _ = try await monitor.snapshot()
        let tokenRequests = session.requests.filter {
            $0.url?.path == "/app/installations/1/access_tokens"
        }
        XCTAssertEqual(tokenRequests.count, 1)
        XCTAssertTrue(session.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28"
        })
        let tokenRequest = try XCTUnwrap(session.requests.first {
            $0.url?.path == "/app/installations/1/access_tokens"
        })
        let tokenBody = try XCTUnwrap(tokenRequest.httpBody)
        let tokenJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: tokenBody) as? [String: Any]
        )
        XCTAssertEqual(tokenJSON["repositories"] as? [String], ["mobile"])
        XCTAssertEqual(
            tokenJSON["permissions"] as? [String: String],
            [
                "actions": "read",
                "organization_self_hosted_runners": "read"
            ]
        )
    }

    func testSnapshotRefreshesAnUnauthorizedInstallationTokenOnce() async throws {
        let session = PoolMonitorRecoverySession(mode: .expiredToken)
        let monitor = makeMonitor(session: session)

        let snapshot = try await monitor.snapshot()

        XCTAssertEqual(snapshot.queuedJobs, 0)
        XCTAssertEqual(snapshot.busyRunners, 0)
        XCTAssertEqual(snapshot.onlineRunnerNames, [])
        XCTAssertEqual(session.issuedTokenCount, 2)
    }

    func testOrganizationScopeDiscoversInstallationRepositoriesAndOmitsRepositoryRestriction() async throws {
        let session = PoolMonitorSession()
        let monitor = GitHubRunnerPoolMonitor(
            auth: MockAuth(),
            session: session,
            organization: "acme",
            repositories: nil,
            matchLabels: ["macos-pool", "release"],
            runnerNames: ["runner-pool", "runner-pool-2"],
            excludedRepositories: ["legacy"]
        )

        let snapshot = try await monitor.snapshot()

        XCTAssertEqual(snapshot.queuedJobs, 1)
        XCTAssertTrue(session.requests.contains { $0.url?.path == "/installation/repositories" })
        XCTAssertFalse(session.requests.contains { $0.url?.path == "/repos/acme/legacy/actions/runs" })
        let tokenRequest = try XCTUnwrap(session.requests.first {
            $0.url?.path == "/app/installations/1/access_tokens"
        })
        let tokenBody = try XCTUnwrap(tokenRequest.httpBody)
        let tokenJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: tokenBody) as? [String: Any]
        )
        XCTAssertNil(tokenJSON["repositories"])
        XCTAssertEqual(
            tokenJSON["permissions"] as? [String: String],
            [
                "actions": "read",
                "organization_self_hosted_runners": "read"
            ]
        )
    }

    func testTokenCreationRefreshesAStaleInstallationIDOnce() async throws {
        let session = PoolMonitorRecoverySession(mode: .staleInstallation)
        let monitor = makeMonitor(session: session)

        _ = try await monitor.snapshot()

        XCTAssertEqual(session.resolvedInstallationCount, 2)
        XCTAssertEqual(session.issuedTokenCount, 1)
    }

    func testRateLimitResponseCarriesRetryAfter() async {
        let session = PoolMonitorRecoverySession(mode: .rateLimited)
        let monitor = makeMonitor(session: session)

        do {
            _ = try await monitor.snapshot()
            XCTFail("expected rate limit error")
        } catch let error as GitHubRunnerPoolMonitorError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfter, 120)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeMonitor(session: URLSessionProtocol) -> GitHubRunnerPoolMonitor {
        GitHubRunnerPoolMonitor(
            auth: MockAuth(),
            session: session,
            organization: "acme",
            repositories: ["mobile"],
            matchLabels: ["macos-pool"],
            runnerNames: ["runner-pool", "runner-pool-2"]
        )
    }
}

private struct FailingPoolCheckMonitor: GitHubRunnerPoolMonitoring {
    let status: Int

    func snapshot() async throws -> GitHubRunnerPoolSnapshot {
        throw GitHubRunnerPoolMonitorError.http(
            status: status,
            body: #"{"message":"Resource not accessible by integration"}"#,
            retryAfter: nil
        )
    }
}

@available(macOS 15.0, *)
final class PoolCheckTests: XCTestCase {
    func testReadSnapshotCannotHideMissingRunnerWritePermission() async throws {
        let snapshot = try await GitHubRunnerPoolMonitor(
            auth: MockAuth(),
            session: PoolMonitorSession(),
            organization: "acme",
            repositories: ["mobile"],
            matchLabels: ["macos-pool", "release"],
            runnerNames: ["runner-pool", "runner-pool-2"]
        ).snapshot()
        XCTAssertEqual(snapshot.queuedJobs, 1)

        do {
            try await PoolCheck.verifyRegistrationAccess(
                poolName: "macos-pool",
                registrationToken: {
                    throw GitHubServiceError.httpError(
                        status: 403,
                        body: #"{"message":"Resource not accessible by integration"}"#
                    )
                }
            )
            XCTFail("expected runner write permission failure")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(
                message.contains("Self-hosted runners: Read and write"),
                message
            )
            XCTAssertTrue(message.contains("HTTP 403"), message)
            XCTAssertFalse(message.contains("Resource not accessible"), message)
        }
    }

    func testRegistrationPreflightExplainsUnselectedRepository() async {
        do {
            try await PoolCheck.verifyRegistrationAccess(
                poolName: "macos-pool",
                registrationToken: {
                    throw GitHubServiceError.httpError(
                        status: 422,
                        body: #"{"message":"Repositories not accessible"}"#
                    )
                }
            )
            XCTFail("expected repository selection failure")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("select every configured repository"), message)
            XCTAssertTrue(message.contains("HTTP 422"), message)
            XCTAssertFalse(message.contains("Repositories not accessible"), message)
        }
    }

    func testMissingActionsPermissionHasActionableFailure() async {
        do {
            _ = try await PoolCheck.verifySnapshot(
                poolName: "macos-pool",
                monitor: FailingPoolCheckMonitor(status: 403)
            )
            XCTFail("expected permission failure")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Actions: Read-only"), message)
            XCTAssertTrue(
                message.contains("Self-hosted runners: Read and write"),
                message
            )
            XCTAssertTrue(message.contains("HTTP 403"), message)
        }
    }

    func testUnselectedRepositoryHasActionableFailure() async {
        do {
            _ = try await PoolCheck.verifySnapshot(
                poolName: "macos-pool",
                monitor: FailingPoolCheckMonitor(status: 422)
            )
            XCTFail("expected repository selection failure")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("select every configured repository"), message)
            XCTAssertTrue(message.contains("HTTP 422"), message)
        }
    }
}
