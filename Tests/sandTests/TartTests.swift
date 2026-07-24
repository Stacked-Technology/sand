import XCTest
@testable import sand

final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let wait: Bool
    }

    var calls: [Call] = []
    var results: [ProcessResult?] = []
    var startCalls: [Call] = []
    var startResults: [Result<ProcessResult, Error>] = []

    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult? {
        calls.append(Call(executable: executable, arguments: arguments, wait: wait))
        if results.isEmpty {
            return ProcessResult(stdout: "", stderr: "", exitCode: 0)
        }
        return results.removeFirst()
    }

    func start(executable: String, arguments: [String]) throws -> ProcessHandle {
        startCalls.append(Call(executable: executable, arguments: arguments, wait: false))
        let result = startResults.isEmpty ? .success(ProcessResult(stdout: "", stderr: "", exitCode: 0)) : startResults.removeFirst()
        return ProcessHandle(
            waitAsync: {
                try result.get()
            },
            terminate: {}
        )
    }
}

private final class OrderedProcessRunner: ProcessRunning, @unchecked Sendable {
    let events: LockedEventLog

    init(events: LockedEventLog) {
        self.events = events
    }

    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult? {
        XCTFail("Unexpected run call")
        return nil
    }

    func start(executable: String, arguments: [String]) throws -> ProcessHandle {
        events.append("start:\(([executable] + arguments).joined(separator: " "))")
        return ProcessHandle(
            waitAsync: {
                ProcessResult(stdout: "", stderr: "", exitCode: 0)
            },
            terminate: {}
        )
    }
}

private actor MockSoftnetPolicyControl: SoftnetPolicyControlling {
    let events: LockedEventLog
    let error: Error?

    init(events: LockedEventLog, error: Error? = nil) {
        self.events = events
        self.error = error
    }

    func replacePolicy(allow: [String], block: [String]) async throws {
        events.append("policy:allow=\(allow.joined(separator: ","));block=\(block.joined(separator: ","))")
        if let error {
            throw error
        }
    }
}

private final class LockedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return events
    }
}

func makeTart(_ runner: ProcessRunning) -> Tart {
    Tart(processRunner: runner, logger: Logger(label: "tart.test", minimumLevel: .info))
}

final class TartTests: XCTestCase {
    func testCloneArgs() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        try await tart.clone(source: "source", name: "ephemeral")
        XCTAssertEqual(runner.calls.first, .init(executable: "tart", arguments: ["clone", "source", "ephemeral"], wait: true))
    }

    func testRunArgs() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        _ = try await tart.run(name: "ephemeral")
        XCTAssertEqual(runner.startCalls.first, .init(executable: "tart", arguments: ["run", "ephemeral", "--no-graphics"], wait: false))
    }

    func testRunArgsWithOptions() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        let options = Tart.RunOptions(
            directoryMounts: [
                Tart.DirectoryMount(hostPath: "/tmp/dir", name: "dir", readOnly: true)
            ],
            noAudio: true,
            noGraphics: false,
            noClipboard: true,
            network: .softnet,
            softnetBlock: "@host"
        )
        _ = try await tart.run(name: "ephemeral", options: options)
        XCTAssertEqual(runner.startCalls.first, .init(
            executable: "tart",
            arguments: [
                "run", "ephemeral", "--no-audio", "--no-clipboard",
                "--net-softnet", "--net-softnet-block", "@host",
                "--dir", "dir:/tmp/dir:ro"
            ],
            wait: false
        ))
    }

    func testDeferredSoftnetBlockUsesControlDescriptorInsteadOfStaticPolicy() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        let options = Tart.RunOptions(
            directoryMounts: [],
            noAudio: true,
            noGraphics: true,
            noClipboard: true,
            network: .softnet,
            softnetBlock: "@host"
        )

        let session = try await tart.run(
            name: "ephemeral",
            options: options,
            deferSoftnetBlock: true
        )

        let arguments = try XCTUnwrap(runner.startCalls.first?.arguments)
        XCTAssertTrue(arguments.contains("--net-softnet-control-fd"))
        XCTAssertFalse(arguments.contains("--net-softnet-block"))
        let controlFlagIndex = try XCTUnwrap(
            arguments.firstIndex(of: "--net-softnet-control-fd")
        )
        XCTAssertEqual(arguments[controlFlagIndex + 1], "3")
        XCTAssertEqual(runner.startCalls.first?.executable, "/bin/sh")
        XCTAssertEqual(session.deferredBlockTargets, ["@host"])
        XCTAssertNotNil(session.policyControl)
    }

    func testDeferredSoftnetBlockRejectsDelimiterOnlyPolicy() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        let options = Tart.RunOptions(
            directoryMounts: [],
            noAudio: true,
            noGraphics: true,
            noClipboard: true,
            network: .softnet,
            softnetBlock: ", ,"
        )

        do {
            _ = try await tart.run(
                name: "ephemeral",
                options: options,
                deferSoftnetBlock: true
            )
            XCTFail("Expected invalid deferred policy to fail closed")
        } catch TartError.invalidSoftnetBlock {
            XCTAssertTrue(runner.startCalls.isEmpty)
        }
    }

    func testDeferredSoftnetControlChannelWorksThroughRealProcessLaunch() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sand-fake-tart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let fakeTart = temporaryDirectory.appendingPathComponent("tart")
        let script = """
        #!/bin/sh
        IFS= read -r request <&3
        printf '%s\\n' '{"jsonrpc":"2.0","id":"sand-network-cutover","result":{"allow":[],"block":["@host"],"ruleCount":1}}' >&3
        """
        try Data(script.utf8).write(to: fakeTart)
        XCTAssertEqual(chmod(fakeTart.path, 0o700), 0)
        let tart = Tart(
            processRunner: SystemProcessRunner(),
            logger: Logger(label: "tart.integration.test", minimumLevel: .info),
            executable: fakeTart.path
        )
        let options = Tart.RunOptions(
            directoryMounts: [],
            noAudio: true,
            noGraphics: true,
            noClipboard: true,
            network: .softnet,
            softnetBlock: "@host"
        )

        let session = try await tart.run(
            name: "ephemeral",
            options: options,
            deferSoftnetBlock: true
        )
        let policyControl = try XCTUnwrap(session.policyControl)
        try await policyControl.replacePolicy(allow: [], block: ["@host"])
        let result = try await session.handle.waitAsync()

        XCTAssertEqual(result.exitCode, 0)
    }

    func testIsolatedCommandAppliesPolicyAfterGuestAgentPreflightAndBeforeRunnerStart() async throws {
        let events = LockedEventLog()
        let tart = makeTart(OrderedProcessRunner(events: events))
        let policy = MockSoftnetPolicyControl(events: events)
        let readiness = try await tart.verifyGuestAgent(name: "ephemeral")

        _ = try await tart.startIsolatedCommand(
            readiness: readiness,
            command: "~/actions-runner/run.sh",
            policyControl: policy,
            blockTargets: ["@host"]
        )

        XCTAssertEqual(events.snapshot(), [
            "start:tart exec ephemeral /bin/bash -lc /usr/bin/true",
            "policy:allow=;block=@host",
            "start:tart exec ephemeral /bin/bash -lc ~/actions-runner/run.sh"
        ])
    }

    func testIsolatedCommandDoesNotStartRunnerWhenPolicyCutoverFails() async throws {
        let events = LockedEventLog()
        let tart = makeTart(OrderedProcessRunner(events: events))
        let policy = MockSoftnetPolicyControl(
            events: events,
            error: SoftnetPolicyControlError.invalidResponse
        )
        let readiness = try await tart.verifyGuestAgent(name: "ephemeral")

        do {
            _ = try await tart.startIsolatedCommand(
                readiness: readiness,
                command: "~/actions-runner/run.sh",
                policyControl: policy,
                blockTargets: ["@host"]
            )
            XCTFail("Expected policy cutover failure")
        } catch SoftnetPolicyControlError.invalidResponse {
            XCTAssertEqual(events.snapshot(), [
                "start:tart exec ephemeral /bin/bash -lc /usr/bin/true",
                "policy:allow=;block=@host"
            ])
        }
    }

    func testSetArgs() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)
        let display = Tart.Display(width: 1920, height: 1080, unit: "px")
        try await tart.set(name: "ephemeral", cpuCores: 4, memoryMb: 4096, display: display, displayRefit: true, diskSizeGb: 80)
        XCTAssertEqual(runner.calls.first, .init(
            executable: "tart",
            arguments: ["set", "ephemeral", "--cpu", "4", "--memory", "4096", "--display", "1920x1080px", "--display-refit", "--disk-size", "80"],
            wait: true
        ))
    }

    func testStopAndDeleteUseSupervisedProcesses() async throws {
        let runner = MockProcessRunner()
        let tart = makeTart(runner)

        try await tart.stop(name: "ephemeral", timeout: 30)
        try await tart.delete(name: "ephemeral")

        XCTAssertEqual(runner.startCalls, [
            .init(
                executable: "tart",
                arguments: ["stop", "ephemeral", "--timeout", "30"],
                wait: false
            ),
            .init(
                executable: "tart",
                arguments: ["delete", "ephemeral"],
                wait: false
            )
        ])
    }

    func testIpArgs() async throws {
        let runner = MockProcessRunner()
        runner.results = [ProcessResult(stdout: "10.0.0.1\n", stderr: "", exitCode: 0)]
        let tart = makeTart(runner)
        let ip = try await tart.ip(name: "ephemeral", wait: 60)
        XCTAssertEqual(ip, "10.0.0.1")
        XCTAssertEqual(runner.calls.first, .init(executable: "tart", arguments: ["ip", "ephemeral", "--wait", "60"], wait: true))
    }

    func testPrepareSkipsPullWhenPresent() async throws {
        let runner = MockProcessRunner()
        runner.results = [ProcessResult(stdout: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest\n", stderr: "", exitCode: 0)]
        let tart = makeTart(runner)
        try await tart.prepare(source: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        XCTAssertEqual(runner.calls, [
            .init(executable: "tart", arguments: ["list", "--source", "oci", "--quiet"], wait: true)
        ])
    }

    func testPreparePullsWhenMissing() async throws {
        let runner = MockProcessRunner()
        runner.results = [
            ProcessResult(stdout: "", stderr: "", exitCode: 0),
            ProcessResult(stdout: "", stderr: "", exitCode: 0)
        ]
        let tart = makeTart(runner)
        try await tart.prepare(source: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        XCTAssertEqual(runner.calls, [
            .init(executable: "tart", arguments: ["list", "--source", "oci", "--quiet"], wait: true),
            .init(executable: "tart", arguments: ["pull", "ghcr.io/cirruslabs/macos-tahoe-xcode:latest"], wait: true)
        ])
    }

    func testIsRunningUsesJsonList() async throws {
        let runner = MockProcessRunner()
        runner.results = [
            ProcessResult(stdout: "[{\"Name\":\"vm-1\",\"Running\":true}]", stderr: "", exitCode: 0)
        ]
        let tart = makeTart(runner)
        let running = try await tart.isRunning(name: "vm-1")
        XCTAssertTrue(running)
        XCTAssertEqual(runner.calls, [
            .init(executable: "tart", arguments: ["list", "--format", "json"], wait: true)
        ])
    }

    func testStatusMissingWhenVmNotFound() async throws {
        let runner = MockProcessRunner()
        runner.results = [
            ProcessResult(stdout: "[]", stderr: "", exitCode: 0)
        ]
        let tart = makeTart(runner)
        let status = try await tart.status(name: "missing")
        XCTAssertEqual(status, .missing)
    }

    func testStatusRunningWhenVmIsRunning() async throws {
        let runner = MockProcessRunner()
        runner.results = [
            ProcessResult(stdout: "[{\"Name\":\"vm-1\",\"Running\":true}]", stderr: "", exitCode: 0)
        ]
        let tart = makeTart(runner)
        let status = try await tart.status(name: "vm-1")
        XCTAssertEqual(status, .running)
    }

    func testStatusStoppedWhenVmIsStopped() async throws {
        let runner = MockProcessRunner()
        runner.results = [
            ProcessResult(stdout: "[{\"Name\":\"vm-1\",\"Running\":false}]", stderr: "", exitCode: 0)
        ]
        let tart = makeTart(runner)
        let status = try await tart.status(name: "vm-1")
        XCTAssertEqual(status, .stopped)
    }
}
