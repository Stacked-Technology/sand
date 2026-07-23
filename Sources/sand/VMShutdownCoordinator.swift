import Foundation

actor VMShutdownCoordinator {
    private var activeName: String?
    private var runHandle: ProcessHandle?
    private var cleanupStarted = false
    private var cleanupTask: Task<Void, Never>?
    private let destroy: @Sendable (String) async -> Void
    private let logger: Logger

    init(destroyer: VMDestroyer, logger: Logger) {
        self.destroy = { name in
            try? await destroyer.destroy(name: name)
        }
        self.logger = logger
    }

    init(
        destroy: @escaping @Sendable (String) async -> Void,
        logger: Logger
    ) {
        self.destroy = destroy
        self.logger = logger
    }

    func activate(name: String) {
        activeName = name
        runHandle = nil
        cleanupStarted = false
        cleanupTask = nil
        logger.info("shutdown coordinator activated for VM \(name)")
    }

    func setRunHandle(_ handle: ProcessHandle) async {
        guard activeName != nil, !cleanupStarted else {
            logger.warning("VM run handle arrived after cleanup started; terminating it")
            await terminateRunHandle(handle)
            return
        }
        runHandle = handle
    }

    func cleanup(reason: String? = nil) async {
        let reasonLabel = reason ?? "unspecified"
        if let cleanupTask {
            logger.debug("cleanup join: already started (reason: \(reasonLabel))")
            await cleanupTask.value
            return
        }
        guard !cleanupStarted, let name = activeName else {
            if cleanupStarted {
                logger.debug("cleanup skipped: already started (reason: \(reasonLabel))")
            } else {
                logger.debug("cleanup skipped: no active VM (reason: \(reasonLabel))")
            }
            return
        }
        cleanupStarted = true
        logger.info("cleanup start for VM \(name) (reason: \(reasonLabel))")
        let activeRunHandle = runHandle
        let destroy = self.destroy
        let task = Task {
            if let activeRunHandle {
                await self.terminateRunHandle(activeRunHandle)
            }
            await destroy(name)
        }
        cleanupTask = task
        await task.value
        logger.info("cleanup complete for VM \(name)")
        activeName = nil
        runHandle = nil
        cleanupTask = nil
    }

    private func terminateRunHandle(_ handle: ProcessHandle) async {
        await handle.terminate()
        if await waitForExit(handle, seconds: 5) {
            return
        }
        logger.warning("tart run process ignored termination; forcing exit")
        await handle.forceTerminate()
        if !(await waitForExit(handle, seconds: 5)) {
            logger.error("tart run process did not exit after SIGKILL")
        }
    }

    private func waitForExit(_ handle: ProcessHandle, seconds: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await handle.waitAsync(terminateOnCancel: false)
                } catch is CancellationError {
                    return false
                } catch {
                    return true
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

}
