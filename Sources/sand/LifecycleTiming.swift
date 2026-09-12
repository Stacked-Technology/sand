import Foundation

/// A wall-clock timestamp paired with a monotonic start point for lifecycle logs.
///
/// Wall-clock values make events easy to correlate with external logs. Durations
/// always use the monotonic uptime clock so clock adjustments cannot produce
/// negative or misleading elapsed values.
struct LifecycleTiming: Equatable, Sendable {
    let startedAt: Date
    private let startedUptimeNanoseconds: UInt64

    init(
        startedAt: Date = Date(),
        startedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.startedAt = startedAt
        self.startedUptimeNanoseconds = startedUptimeNanoseconds
    }

    func elapsedMilliseconds(
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        guard nowUptimeNanoseconds >= startedUptimeNanoseconds else {
            return 0
        }
        return (nowUptimeNanoseconds - startedUptimeNanoseconds) / 1_000_000
    }

    func startMetadata() -> String {
        "started_at=\(Self.timestamp(startedAt))"
    }

    func completionMetadata(
        at date: Date = Date(),
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> String {
        "at=\(Self.timestamp(date)) elapsed_ms=\(elapsedMilliseconds(nowUptimeNanoseconds: nowUptimeNanoseconds))"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct RunnerLifecycleContext: Equatable, Sendable {
    let id: String
    let vmName: String
    let runnerName: String
    let timing: LifecycleTiming

    init(
        vmName: String,
        runnerName: String,
        id: String = UUID().uuidString,
        timing: LifecycleTiming = LifecycleTiming()
    ) {
        self.id = id
        self.vmName = vmName
        self.runnerName = runnerName
        self.timing = timing
    }

    func metadata() -> String {
        "lifecycle=\(Self.safeIdentifier(id)) vm=\(Self.safeIdentifier(vmName)) runner=\(Self.safeIdentifier(runnerName))"
    }

    private static func safeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:/-"))
        let filtered = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let compact = filtered.isEmpty ? "unknown" : filtered
        return compact.count <= 128 ? compact : String(compact.prefix(125)) + "..."
    }
}

enum ProcessOutputStream: Sendable {
    case stdout
    case stderr
}

typealias ProcessOutputHandler = @Sendable (ProcessOutputStream, String) -> Void

/// Emits bounded lifecycle events for the well-known Actions runner output
/// markers without persisting the output line itself.
final class RunnerOutputObserver: @unchecked Sendable {
    private let logger: Logger
    private let lifecycle: RunnerLifecycleContext
    private let timing: LifecycleTiming
    private let lock = NSLock()
    private var listenerReady = false
    private var jobAccepted = false

    init(logger: Logger, lifecycle: RunnerLifecycleContext, timing: LifecycleTiming) {
        self.logger = logger
        self.lifecycle = lifecycle
        self.timing = timing
    }

    func observe(_: ProcessOutputStream, line: String) {
        let normalized = line.lowercased()
        if normalized.contains("listening for jobs") {
            lock.lock()
            let shouldLog = !listenerReady
            listenerReady = true
            lock.unlock()
            if shouldLog {
                logger.info(
                    "lifecycle event=runner_listener_ready source=run.sh "
                        + "\(lifecycle.metadata()) \(timing.completionMetadata())"
                )
            }
        }
        if normalized.contains("running job") || normalized.contains("job started") {
            lock.lock()
            let shouldLog = !jobAccepted
            jobAccepted = true
            lock.unlock()
            if shouldLog {
                logger.info(
                    "lifecycle event=runner_job_accepted source=run.sh job_id=unavailable "
                        + "\(lifecycle.metadata()) \(timing.completionMetadata())"
                )
            }
        }
    }
}
