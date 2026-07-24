import Foundation
import Darwin

private final class PipeCapture: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "sand.process-pipe-capture")
    private var data = Data()
    private var finished = false

    init(pipe: Pipe, maximumBytes: Int) {
        fileHandle = pipe.fileHandleForReading
        self.maximumBytes = maximumBytes
        fileHandle.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle)
        }
    }

    func finish() -> String {
        fileHandle.readabilityHandler = nil
        return queue.sync {
            if !finished {
                finished = true
                drainNonBlocking()
                try? fileHandle.close()
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        data.append(chunk)
        if data.count > maximumBytes {
            data.removeFirst(data.count - maximumBytes)
        }
    }

    private func drainNonBlocking() {
        let descriptor = fileHandle.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            return
        }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard bytesRead > 0 else {
                return
            }
            append(Data(buffer.prefix(bytesRead)))
        }
    }

    private func consumeAvailableData(from handle: FileHandle) {
        queue.sync {
            guard !finished else {
                return
            }
            append(handle.availableData)
        }
    }
}

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

actor ProcessHandle {
    private let process: Process?
    private let stdoutCapture: PipeCapture?
    private let stderrCapture: PipeCapture?
    private let command: [String]?
    private let waitAsyncBlock: (() async throws -> ProcessResult)?
    private let terminateBlock: (() -> Void)?
    private var cachedResult: Result<ProcessResult, Error>?
    private var waiters: [UUID: CheckedContinuation<ProcessResult, Error>] = [:]
    private var terminationHandlerInstalled = false

    init(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        command: [String],
        maximumCaptureBytes: Int
    ) {
        self.process = process
        self.stdoutCapture = PipeCapture(pipe: stdoutPipe, maximumBytes: maximumCaptureBytes)
        self.stderrCapture = PipeCapture(pipe: stderrPipe, maximumBytes: maximumCaptureBytes)
        self.command = command
        self.waitAsyncBlock = nil
        self.terminateBlock = nil
    }

    init(
        waitAsync: @escaping () async throws -> ProcessResult,
        terminate: @escaping () -> Void
    ) {
        self.process = nil
        self.stdoutCapture = nil
        self.stderrCapture = nil
        self.command = nil
        self.waitAsyncBlock = waitAsync
        self.terminateBlock = terminate
    }

    func waitAsync(terminateOnCancel: Bool = true) async throws -> ProcessResult {
        if let waitAsyncBlock {
            return try await waitAsyncBlock()
        }
        if let cachedResult {
            return try cachedResult.get()
        }
        guard let process else {
            throw ProcessRunnerError.invalidCommand
        }
        if !process.isRunning {
            return try resolveResult().get()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if let cachedResult {
                    continuation.resume(with: cachedResult)
                    return
                }
                waiters[waiterID] = continuation
                installTerminationHandlerIfNeeded()
                if !process.isRunning {
                    waiters.removeValue(forKey: waiterID)
                    continuation.resume(with: resolveResult())
                }
            }
        }, onCancel: {
            Task { await cancelWaiter(id: waiterID, terminateProcess: terminateOnCancel) }
        })
    }

    func terminate() {
        if let terminateBlock {
            terminateBlock()
            return
        }
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
    }

    func forceTerminate() {
        guard let process, process.isRunning else {
            return
        }
        kill(process.processIdentifier, SIGKILL)
    }

    private func resolveResult() -> Result<ProcessResult, Error> {
        if let cachedResult {
            return cachedResult
        }
        guard let process, let stdoutCapture, let stderrCapture, let command else {
            let failure = Result<ProcessResult, Error>.failure(ProcessRunnerError.invalidCommand)
            cachedResult = failure
            return failure
        }
        let stdout = stdoutCapture.finish()
        let stderr = stderrCapture.finish()
        let exitCode = process.terminationStatus
        let result: Result<ProcessResult, Error>
        if exitCode != 0 {
            result = .failure(ProcessRunnerError.failed(exitCode: exitCode, stdout: stdout, stderr: stderr, command: command))
        } else {
            result = .success(ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode))
        }
        cachedResult = result
        return result
    }

    private func installTerminationHandlerIfNeeded() {
        guard !terminationHandlerInstalled, let process else {
            return
        }
        terminationHandlerInstalled = true
        process.terminationHandler = { [weak self] _ in
            guard let self else {
                return
            }
            Task { await self.processDidExit() }
        }
    }

    private func processDidExit() {
        let result = resolveResult()
        resumeWaiters(with: result)
    }

    private func resumeWaiters(with result: Result<ProcessResult, Error>) {
        let pending = waiters
        waiters = [:]
        for continuation in pending.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(id: UUID, terminateProcess: Bool) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
        if terminateProcess, cachedResult == nil, let process, process.isRunning {
            process.terminate()
        }
    }
}

func waitForProcess(
    _ handle: ProcessHandle,
    timeout: Duration,
    terminationGrace: Duration = .seconds(5)
) async throws -> ProcessResult {
    let result: ProcessResult?
    do {
        result = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
            group.addTask {
                try await handle.waitAsync(terminateOnCancel: false)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    } catch is CancellationError {
        await Task.detached {
            await terminateProcess(handle, grace: terminationGrace)
        }.value
        throw CancellationError()
    }
    if let result {
        return result
    }

    await terminateProcess(handle, grace: terminationGrace)
    throw ProcessRunnerError.timedOut
}

private func terminateProcess(_ handle: ProcessHandle, grace: Duration) async {
    await handle.terminate()
    if await processExits(handle, within: grace) {
        return
    }
    await handle.forceTerminate()
    _ = await processExits(handle, within: grace)
}

private func processExits(_ handle: ProcessHandle, within timeout: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            do {
                _ = try await handle.waitAsync(terminateOnCancel: false)
                return true
            } catch is CancellationError {
                return false
            } catch {
                return true
            }
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

enum ProcessRunnerError: Error {
    case failed(exitCode: Int32, stdout: String, stderr: String, command: [String])
    case invalidCommand
    case timedOut
}

protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult?
    func start(executable: String, arguments: [String]) throws -> ProcessHandle
    func startBounded(
        executable: String,
        arguments: [String],
        maximumCaptureBytes: Int
    ) throws -> ProcessHandle
    func startBounded(
        executable: String,
        arguments: [String],
        maximumCaptureBytes: Int,
        standardInputDescriptor: Int32
    ) throws -> ProcessHandle
}

extension ProcessRunning {
    func startBounded(
        executable: String,
        arguments: [String],
        maximumCaptureBytes _: Int
    ) throws -> ProcessHandle {
        try start(executable: executable, arguments: arguments)
    }

    func startBounded(
        executable: String,
        arguments: [String],
        maximumCaptureBytes: Int,
        standardInputDescriptor _: Int32
    ) throws -> ProcessHandle {
        try startBounded(
            executable: executable,
            arguments: arguments,
            maximumCaptureBytes: maximumCaptureBytes
        )
    }
}

struct SystemProcessRunner: ProcessRunning, Sendable {
    private static let commandCaptureBytes = 4 * 1_024 * 1_024
    private static let streamingCaptureBytes = 1_024 * 1_024

    func run(executable: String, arguments: [String], wait: Bool) async throws -> ProcessResult? {
        let handle = try startBounded(
            executable: executable,
            arguments: arguments,
            maximumCaptureBytes: Self.commandCaptureBytes
        )
        if !wait {
            Task {
                _ = try? await handle.waitAsync()
            }
            return nil
        }
        return try await handle.waitAsync()
    }

    func start(executable: String, arguments: [String]) throws -> ProcessHandle {
        try start(
            executable: executable,
            arguments: arguments,
            maximumCaptureBytes: Self.streamingCaptureBytes
        )
    }

    func startBounded(
        executable: String,
        arguments: [String],
        maximumCaptureBytes: Int
    ) throws -> ProcessHandle {
        try start(
            executable: executable,
            arguments: arguments,
            maximumCaptureBytes: maximumCaptureBytes
        )
    }

    func startBounded(
        executable: String,
        arguments: [String],
        maximumCaptureBytes: Int,
        standardInputDescriptor: Int32
    ) throws -> ProcessHandle {
        try start(
            executable: executable,
            arguments: arguments,
            maximumCaptureBytes: maximumCaptureBytes,
            standardInputDescriptor: standardInputDescriptor
        )
    }

    private func start(
        executable: String,
        arguments: [String],
        maximumCaptureBytes: Int,
        standardInputDescriptor: Int32? = nil
    ) throws -> ProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let command = [executable] + arguments
        process.arguments = command
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if let standardInputDescriptor {
            process.standardInput = FileHandle(
                fileDescriptor: standardInputDescriptor,
                closeOnDealloc: false
            )
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        return ProcessHandle(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            command: command,
            maximumCaptureBytes: maximumCaptureBytes
        )
    }
}
