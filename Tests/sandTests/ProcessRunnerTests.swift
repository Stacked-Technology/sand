import Darwin
import Foundation
import XCTest
@testable import sand

final class ProcessRunnerTests: XCTestCase {
    func testStartBoundedMapsDuplexSocketToChildStandardInput() async throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let parentDescriptor = descriptors[0]
        let childDescriptor = descriptors[1]
        defer {
            Darwin.close(parentDescriptor)
        }
        XCTAssertEqual(fcntl(childDescriptor, F_SETFD, FD_CLOEXEC), 0)

        let runner = SystemProcessRunner()
        let handle = try runner.startBounded(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "exec 3<&0; exec 0</dev/null; IFS= read -r value <&3; printf '%s' \"$value\" >&3"
            ],
            maximumCaptureBytes: 1_024,
            standardInputDescriptor: childDescriptor
        )
        Darwin.close(childDescriptor)

        let payload = Array("inherited\n".utf8)
        XCTAssertEqual(
            payload.withUnsafeBytes {
                Darwin.write(parentDescriptor, $0.baseAddress, $0.count)
            },
            payload.count
        )
        XCTAssertEqual(shutdown(parentDescriptor, SHUT_WR), 0)

        var pollDescriptor = pollfd(
            fd: parentDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        XCTAssertGreaterThan(Darwin.poll(&pollDescriptor, 1, 1_000), 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(parentDescriptor, &buffer, buffer.count)
        XCTAssertEqual(
            String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self),
            "inherited"
        )
        let result = try await handle.waitAsync()
        XCTAssertEqual(result.stdout, "")
    }

    func testDetachedProcessCannotBlockOnUndrainedOutputPipes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sand-process-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let marker = temporaryDirectory.appendingPathComponent("completed")
        let script = """
i=0
while [ "$i" -lt 20000 ]; do
  printf 'detached-process-output-that-must-not-fill-a-pipe\\n'
  i=$((i + 1))
done
touch '\(marker.path)'
"""

        let runner = SystemProcessRunner()
        let handle = try runner.startBounded(
            executable: "/bin/sh",
            arguments: ["-c", script],
            maximumCaptureBytes: 65_536
        )
        let result = try await handle.waitAsync()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 65_536)
        XCTAssertTrue(result.stdout.hasSuffix("detached-process-output-that-must-not-fill-a-pipe\n"))
    }

    func testCommandCapturePreservesStructuredOutputWithinLimit() async throws {
        let runner = SystemProcessRunner()
        let result = try await runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while [ \"$i\" -lt 100000 ]; do printf x; i=$((i + 1)); done"],
            wait: true
        )

        XCTAssertEqual(result?.stdout.count, 100_000)
    }

    func testDefaultStreamingCaptureIsBounded() async throws {
        let runner = SystemProcessRunner()
        let handle = try runner.start(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1200000 count=1 2>/dev/null"]
        )

        let result = try await handle.waitAsync()

        XCTAssertEqual(result.stdout.count, 1_024 * 1_024)
        XCTAssertTrue(result.stdout.hasSuffix("\0"))
    }

    func testProcessExitDoesNotWaitForDescendantOwnedPipe() async throws {
        let runner = SystemProcessRunner()
        let handle = try runner.start(
            executable: "/bin/sh",
            arguments: ["-c", "(sleep 2) & printf done"]
        )
        let clock = ContinuousClock()
        let started = clock.now

        let result = try await handle.waitAsync()

        XCTAssertEqual(result.stdout, "done")
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testWaitForProcessForcesExitAfterDeadline() async throws {
        let runner = SystemProcessRunner()
        let handle = try runner.start(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"]
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await waitForProcess(
                handle,
                timeout: .milliseconds(50),
                terminationGrace: .milliseconds(50)
            )
            XCTFail("Expected process timeout")
        } catch ProcessRunnerError.timedOut {
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
        }
    }

    func testWaitForProcessCancellationTerminatesChild() async throws {
        let runner = SystemProcessRunner()
        let handle = try runner.start(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"]
        )
        let waiter = Task {
            try await waitForProcess(
                handle,
                timeout: .seconds(10),
                terminationGrace: .milliseconds(50)
            )
        }
        try await Task.sleep(for: .milliseconds(50))

        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Cancellation must not return until the child has been terminated.
        }

        do {
            _ = try await waitForProcess(
                handle,
                timeout: .milliseconds(100),
                terminationGrace: .milliseconds(50)
            )
            XCTFail("Expected terminated process failure")
        } catch ProcessRunnerError.failed {
            // The child was already reaped instead of surviving cancellation.
        }
    }

    func testBoundedCaptureDecodesSplitUTF8Lossily() async throws {
        let runner = SystemProcessRunner()
        let handle = try runner.startBounded(
            executable: "/bin/sh",
            arguments: ["-c", "i=0; while [ \"$i\" -lt 40000 ]; do printf 'é'; i=$((i + 1)); done"],
            maximumCaptureBytes: 65_535
        )

        let result = try await handle.waitAsync()

        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertTrue(result.stdout.hasSuffix("é"))
    }
}
