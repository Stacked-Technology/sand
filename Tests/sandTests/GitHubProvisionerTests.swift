import Foundation
import XCTest
@testable import sand

final class GitHubProvisionerTests: XCTestCase {
    func testRunnerCommandIsSeparatedFromTrustedSetupCommands() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil
        )

        let plan = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: "2.999.0"
        )

        XCTAssertEqual(plan.runnerCommand, "~/actions-runner/run.sh")
        XCTAssertFalse(plan.setupCommands.contains(plan.runnerCommand))
        XCTAssertTrue(plan.setupCommands.contains { $0.contains("config.sh") })
    }

    func testScriptWithExtraLabels() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: "repo",
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: ["fast", "arm64"]
        )
        let runnerVersion = "2.999.0"
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: runnerVersion
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--labels sand,fast,arm64"))
        XCTAssertTrue(joined.contains("--url https://github.com/org/repo"))
        XCTAssertTrue(joined.contains("actions/runner/releases/download"))
        XCTAssertTrue(joined.contains("version=\"\(runnerVersion)\""))
        XCTAssertFalse(joined.contains("runner cache"))
    }

    func testScriptWithDefaultLabels() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil
        )
        let runnerVersion = "2.999.0"
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: runnerVersion
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--labels sand"))
        XCTAssertTrue(joined.contains("--url https://github.com/org"))
        XCTAssertTrue(joined.contains("actions-runner-${runner_os}-${runner_arch}"))
        XCTAssertTrue(joined.contains("version=\"\(runnerVersion)\""))
        XCTAssertFalse(joined.contains("runner cache"))
        XCTAssertFalse(joined.contains("--runnergroup"))
    }

    func testScriptDefaultsToEphemeralRunner() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil
        )
        let runnerVersion = "2.999.0"
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: runnerVersion
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--ephemeral"))
    }

    func testScriptCanCreatePersistentRunner() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            ephemeral: false,
            extraLabels: nil
        )
        let runnerVersion = "2.999.0"
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: runnerVersion
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertFalse(joined.contains("--ephemeral"))
    }

    func testScriptWithRunnerGroup() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: nil,
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: "Mac Runner's"
        )
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: "2.999.0"
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("--runnergroup 'Mac Runner'\\''s'"))
    }

    func testScriptIncludesRunnerCacheLogic() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: "repo",
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil
        )
        let runnerVersion = "2.999.0"
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: runnerVersion,
            cacheDirectory: "sand-cache"
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("runner cache hit"))
        XCTAssertTrue(joined.contains("runner cache miss"))
        XCTAssertTrue(joined.contains("runner cache unavailable"))
        XCTAssertTrue(joined.contains("cache_dir="))
        XCTAssertTrue(joined.contains("cache_file="))
        XCTAssertTrue(joined.contains("version=\"\(runnerVersion)\""))
    }

    func testScriptUsesRunnerCacheDirectoryValue() {
        let provisioner = GitHubProvisioner()
        let config = GitHubProvisionerConfig(
            appId: 1,
            organization: "org",
            repository: "repo",
            privateKeyPath: "/tmp/key.pem",
            runnerName: "runner-1",
            extraLabels: nil
        )
        let cacheDirectory = "/var/tmp/runner-cache"
        let runnerVersion = "2.999.0"
        let script = provisioner.script(
            config: config,
            runnerToken: "token",
            runnerVersion: runnerVersion,
            cacheDirectory: cacheDirectory
        )
        let joined = script.allCommands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("cache_dir_name=\"\(cacheDirectory)\""))
        XCTAssertTrue(joined.contains("version=\"\(runnerVersion)\""))
    }
}
