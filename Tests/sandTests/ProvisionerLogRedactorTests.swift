import XCTest
@testable import sand

final class ProvisionerLogRedactorTests: XCTestCase {
    func testRedactsUnquotedRunnerTokenFromCommandAndOutput() {
        let secret = "temporary-registration-token"
        let redactor = ProvisionerLogRedactor(
            command: "~/actions-runner/config.sh --url https://github.com/org --token \(secret) --ephemeral"
        )

        XCTAssertEqual(
            redactor.redact("configured with \(secret)"),
            "configured with [REDACTED]"
        )
        XCTAssertFalse(redactor.redact("--token \(secret)").contains(secret))
    }

    func testRedactsQuotedAndEqualsTokenForms() {
        let singleQuoted = ProvisionerLogRedactor(command: "config.sh --token 'single-secret'")
        let doubleQuoted = ProvisionerLogRedactor(command: #"config.sh --token="double-secret""#)

        XCTAssertEqual(singleQuoted.redact("'single-secret'"), "'[REDACTED]'")
        XCTAssertEqual(doubleQuoted.redact(#""double-secret""#), #""[REDACTED]""#)
    }

    func testDoesNotRedactUnrelatedCommands() {
        let command = "echo ordinary-output"
        let redactor = ProvisionerLogRedactor(command: command)

        XCTAssertEqual(redactor.redact(command), command)
    }

    func testRedactsTokenFromProcessFailureDetails() {
        let secret = "temporary-registration-token"
        let redactor = ProvisionerLogRedactor(command: "config.sh --token \(secret)")
        let failure = ProcessRunnerError.failed(
            exitCode: 1,
            stdout: "stdout \(secret)",
            stderr: "stderr \(secret)",
            command: ["ssh", "config.sh --token \(secret)"]
        )

        guard case let ProcessRunnerError.failed(_, stdout, stderr, command) = redactor.redact(failure) else {
            return XCTFail("Expected a process runner failure")
        }
        XCTAssertFalse(stdout.contains(secret))
        XCTAssertFalse(stderr.contains(secret))
        XCTAssertFalse(command.joined(separator: " ").contains(secret))
    }
}
