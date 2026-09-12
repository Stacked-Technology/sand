import Foundation
import Testing

@testable import sand

private enum LifecycleTestError: Error {
    case prepare
}

private struct FailingProcessRunner: ProcessRunning, Sendable {
    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult? {
        throw LifecycleTestError.prepare
    }

    func start(executable: String, arguments: [String]) throws -> ProcessHandle {
        ProcessHandle(
            waitAsync: {
                ProcessResult(stdout: "", stderr: "", exitCode: 0)
            },
            terminate: {}
        )
    }
}

struct LifecycleTimingTests {
    @Test
    func elapsedUsesMonotonicClockAndBoundsClockRollback() {
        let timing = LifecycleTiming(
            startedAt: Date(timeIntervalSince1970: 0),
            startedUptimeNanoseconds: 1_000_000_000
        )

        #expect(timing.elapsedMilliseconds(nowUptimeNanoseconds: 2_234_000_000) == 1_234)
        #expect(timing.elapsedMilliseconds(nowUptimeNanoseconds: 999_000_000) == 0)
        #expect(timing.startMetadata() == "started_at=1970-01-01T00:00:00.000Z")
        #expect(
            timing.completionMetadata(
                at: Date(timeIntervalSince1970: 1),
                nowUptimeNanoseconds: 2_000_000_000
            ) == "at=1970-01-01T00:00:01.000Z elapsed_ms=1000"
        )
    }

    @Test
    func runnerOutputObserverLogsMarkersWithoutOutputLines() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let logger = Logger(label: "test.lifecycle", minimumLevel: .info, sink: sink)
        let timing = LifecycleTiming(
            startedAt: Date(timeIntervalSince1970: 0),
            startedUptimeNanoseconds: 1
        )
        let lifecycle = RunnerLifecycleContext(
            vmName: "runner-vm",
            runnerName: "runner-1",
            id: "lifecycle-1",
            timing: timing
        )
        let observer = RunnerOutputObserver(logger: logger, lifecycle: lifecycle, timing: timing)

        observer.observe(.stdout, line: "Listening for Jobs token=secret")
        observer.observe(.stdout, line: "Listening for Jobs token=secret")
        observer.observe(.stdout, line: "Running job secret")
        observer.observe(.stderr, line: "Running job secret")

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.components(separatedBy: "runner_listener_ready").count - 1 == 1)
        #expect(contents.components(separatedBy: "runner_job_accepted").count - 1 == 1)
        #expect(contents.contains("lifecycle=lifecycle-1 vm=runner-vm runner=runner-1"))
        #expect(!contents.contains("secret"))
    }

    @Test
    func runnerFailureClosesPhaseAndLifecycleTimings() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("sand.log").path
        let sink = try LogFileSink(path: path)
        let logger = Logger(label: "test.lifecycle.failure", minimumLevel: .info, sink: sink)
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "oci://base", path: nil),
            hardware: nil,
            mounts: [],
            cache: nil,
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let config = Config.RunnerConfig(
            name: "runner-vm",
            vm: vm,
            provisioner: Config.Provisioner(
                type: .script,
                script: Config.Provisioner.Script(run: "echo ready"),
                github: nil
            ),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: nil
        )
        let runner = Runner(
            tart: Tart(processRunner: FailingProcessRunner(), logger: logger),
            github: nil,
            provisioner: GitHubProvisioner(),
            runnerVersionResolver: GitHubRunnerVersionResolver(),
            config: config,
            shutdownCoordinator: VMShutdownCoordinator(destroy: { _ in }, logger: logger),
            control: RunnerControl(),
            vmName: "runner-vm",
            logLabel: "lifecycle.failure",
            logLevel: .info,
            logSink: sink
        )
        var didThrow = false
        do {
            try await runner.run(
                lifecycle: RunnerLifecycleContext(
                    vmName: "runner-vm",
                    runnerName: "runner-1",
                    id: "failure-lifecycle",
                    timing: LifecycleTiming(
                        startedAt: Date(timeIntervalSince1970: 0),
                        startedUptimeNanoseconds: 1
                    )
                )
            )
        } catch LifecycleTestError.prepare {
            didThrow = true
        }
        #expect(didThrow)

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("phase=prepare outcome=failed"))
        #expect(contents.contains("event=runner_lifecycle_end"))
        #expect(contents.contains("elapsed_ms="))
    }
}
