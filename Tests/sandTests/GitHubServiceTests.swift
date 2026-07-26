import Foundation
import XCTest
@testable import sand

final class MockAuth: GitHubAuthenticating, @unchecked Sendable {
    func token(now: Date) throws -> String {
        return "jwt"
    }
}

final class MockSession: URLSessionProtocol, @unchecked Sendable {
    var responses: [String: (Data, Int)] = [:]
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let response = responses[path] else {
            throw NSError(domain: "missing", code: 1)
        }
        let url = request.url ?? URL(string: "https://api.github.com")!
        let http = HTTPURLResponse(url: url, statusCode: response.1, httpVersion: nil, headerFields: nil)!
        return (response.0, http)
    }
}

final class GitHubServiceTests: XCTestCase {
    func testRepoLevelPaths() async throws {
        let session = MockSession()
        session.responses["/repos/org/repo/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/repos/org/repo/actions/runners/registration-token"] = (Data("{\"token\":\"runner\"}".utf8), 200)
        let service = GitHubService(auth: MockAuth(), session: session, organization: "org", repository: "repo")
        let token = try await service.runnerRegistrationToken()
        XCTAssertEqual(token, "runner")
        XCTAssertEqual(session.requests.map { $0.url?.path ?? "" }, [
            "/repos/org/repo/installation",
            "/app/installations/1/access_tokens",
            "/repos/org/repo/actions/runners/registration-token"
        ])
    }

    func testOrganizationRegistrationCanUseNarrowInstallationToken() async throws {
        let session = MockSession()
        session.responses["/orgs/org/installation"] = (Data("{\"id\":1}".utf8), 200)
        session.responses["/app/installations/1/access_tokens"] = (Data("{\"token\":\"access\"}".utf8), 200)
        session.responses["/orgs/org/actions/runners/registration-token"] = (Data("{\"token\":\"runner\"}".utf8), 200)
        let service = GitHubService(
            auth: MockAuth(),
            session: session,
            organization: "org",
            repository: nil
        )

        let token = try await service.runnerRegistrationToken(
            installationRepositories: ["mobile"],
            installationPermissions: [
                "organization_self_hosted_runners": "write"
            ]
        )

        XCTAssertEqual(token, "runner")
        let accessRequest = try XCTUnwrap(session.requests.first {
            $0.url?.path == "/app/installations/1/access_tokens"
        })
        XCTAssertEqual(
            accessRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        let body = try XCTUnwrap(accessRequest.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["repositories"] as? [String], ["mobile"])
        XCTAssertEqual(
            payload["permissions"] as? [String: String],
            ["organization_self_hosted_runners": "write"]
        )
    }
}
