import Foundation

enum TartError: Error {
    case emptyIP
    case invalidSoftnetBlock
}

struct Tart: Sendable {
    enum VMStatus {
        case missing
        case stopped
        case running
    }
    struct DirectoryMount: Equatable {
        let hostPath: String
        let name: String
        let readOnly: Bool

        var runArgument: String {
            var options: [String] = []
            if readOnly {
                options.append("ro")
            }
            if options.isEmpty {
                return "\(name):\(hostPath)"
            }
            return "\(name):\(hostPath):" + options.joined(separator: ",")
        }
    }

    struct RunOptions {
        enum Network: Equatable {
            case `default`
            case softnet
        }

        let directoryMounts: [DirectoryMount]
        let noAudio: Bool
        let noGraphics: Bool
        let noClipboard: Bool
        let network: Network
        let softnetBlock: String?

        static let `default` = RunOptions(
            directoryMounts: [],
            noAudio: false,
            noGraphics: true,
            noClipboard: false,
            network: .default,
            softnetBlock: nil
        )
    }

    struct RunSession {
        let handle: ProcessHandle
        let policyControl: SoftnetPolicyControl?
        let deferredBlockTargets: [String]
    }

    struct GuestAgentReadiness: Sendable {
        fileprivate let vmName: String
    }

    struct Display {
        let width: Int
        let height: Int
        let unit: String?

        var argument: String {
            let suffix = unit.map { $0 } ?? ""
            return "\(width)x\(height)\(suffix)"
        }
    }

    let processRunner: ProcessRunning
    let logger: Logger
    let executable: String

    init(
        processRunner: ProcessRunning,
        logger: Logger,
        executable: String = "tart"
    ) {
        self.processRunner = processRunner
        self.logger = logger
        self.executable = executable
    }

    func prepare(source: String) async throws {
        if isOCISource(source) {
            if try await hasOCI(source: source) {
                return
            }
            try await pull(source: source)
        }
    }

    func pull(source: String) async throws {
        _ = try await run(arguments: ["pull", source], wait: true)
    }

    func clone(source: String, name: String) async throws {
        _ = try await run(arguments: ["clone", source, name], wait: true)
    }

    func set(
        name: String,
        cpuCores: Int?,
        memoryMb: Int?,
        display: Display?,
        displayRefit: Bool?,
        diskSizeGb: Int?
    ) async throws {
        var arguments = ["set", name]
        if let cpuCores {
            arguments.append(contentsOf: ["--cpu", String(cpuCores)])
        }
        if let memoryMb {
            arguments.append(contentsOf: ["--memory", String(memoryMb)])
        }
        if let display {
            arguments.append(contentsOf: ["--display", display.argument])
        }
        if let displayRefit {
            arguments.append(displayRefit ? "--display-refit" : "--no-display-refit")
        }
        if let diskSizeGb {
            arguments.append(contentsOf: ["--disk-size", String(diskSizeGb)])
        }
        guard arguments.count > 2 else {
            return
        }
        _ = try await run(arguments: arguments, wait: true)
    }

    func run(
        name: String,
        options: RunOptions = .default,
        deferSoftnetBlock: Bool = false
    ) async throws -> RunSession {
        var arguments = ["run", name]
        var policyControl: SoftnetPolicyControl?
        var deferredBlockTargets: [String] = []
        if options.noGraphics {
            arguments.append("--no-graphics")
        }
        if options.noAudio {
            arguments.append("--no-audio")
        }
        if options.noClipboard {
            arguments.append("--no-clipboard")
        }
        if options.network == .softnet {
            arguments.append("--net-softnet")
            if let softnetBlock = options.softnetBlock {
                if deferSoftnetBlock {
                    deferredBlockTargets = SoftnetPolicyTargets.parse(softnetBlock)
                    guard !deferredBlockTargets.isEmpty,
                          deferredBlockTargets.count <= SoftnetPolicyTargets.maximumTargets,
                          SoftnetPolicyTargets.normalized(deferredBlockTargets) != nil else {
                        throw TartError.invalidSoftnetBlock
                    }
                    let control = try SoftnetPolicyControl()
                    policyControl = control
                    arguments.append(contentsOf: [
                        "--net-softnet-control-fd",
                        "3"
                    ])
                } else {
                    arguments.append(contentsOf: ["--net-softnet-block", softnetBlock])
                }
            }
        }
        for mount in options.directoryMounts {
            arguments.append("--dir")
            arguments.append(mount.runArgument)
        }
        logger.debug("tart \(arguments.joined(separator: " "))")
        do {
            let handle: ProcessHandle
            if let policyControl {
                // Foundation's Process closes arbitrary inherited descriptors.
                // It does preserve standard input, so carry the duplex socket as
                // fd 0 and remap it to fd 3 before Tart validates the control fd.
                handle = try processRunner.startBounded(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "exec 3<&0; exec 0</dev/null; exec \"$0\" \"$@\"",
                        executable
                    ] + arguments,
                    maximumCaptureBytes: 65_536,
                    standardInputDescriptor: policyControl.inheritedDescriptor
                )
            } else {
                handle = try processRunner.startBounded(
                    executable: executable,
                    arguments: arguments,
                    maximumCaptureBytes: 65_536
                )
            }
            await policyControl?.childDidLaunch()
            return RunSession(
                handle: handle,
                policyControl: policyControl,
                deferredBlockTargets: deferredBlockTargets
            )
        } catch {
            await policyControl?.close()
            throw error
        }
    }

    func exec(
        name: String,
        command: String,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let handle = try startExec(name: name, command: command)
        return try await waitForProcess(handle, timeout: timeout)
    }

    func startExec(name: String, command: String) throws -> ProcessHandle {
        logger.debug("tart exec \(name) \(command)")
        return try processRunner.startBounded(
            executable: executable,
            arguments: ["exec", name, "/bin/bash", "-lc", command],
            maximumCaptureBytes: 1_024 * 1_024
        )
    }

    func verifyGuestAgent(name: String) async throws -> GuestAgentReadiness {
        logger.info("verify Tart guest-agent control channel before runner registration")
        _ = try await exec(name: name, command: "/usr/bin/true")
        return GuestAgentReadiness(vmName: name)
    }

    func startIsolatedCommand(
        readiness: GuestAgentReadiness,
        command: String,
        policyControl: any SoftnetPolicyControlling,
        blockTargets: [String]
    ) async throws -> ProcessHandle {
        try await policyControl.replacePolicy(allow: [], block: blockTargets)
        logger.info("Softnet network isolation applied")
        return try startExec(name: readiness.vmName, command: command)
    }

    func ip(name: String, wait: Int) async throws -> String {
        let result = try await run(arguments: ["ip", name, "--wait", String(wait)], wait: true)
        let value = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            throw TartError.emptyIP
        }
        return value
    }

    func stop(name: String, timeout: Int? = nil) async throws {
        var arguments = ["stop", name]
        if let timeout {
            arguments.append(contentsOf: ["--timeout", String(timeout)])
        }
        _ = try await run(
            arguments: arguments,
            timeout: .seconds((timeout ?? 30) + 5)
        )
    }

    func delete(name: String) async throws {
        _ = try await run(
            arguments: ["delete", name],
            timeout: .seconds(15)
        )
    }

    func isRunning(name: String) async throws -> Bool {
        return try await status(name: name) == .running
    }

    func status(name: String) async throws -> VMStatus {
        let result = try await run(arguments: ["list", "--format", "json"], wait: true)
        let output = result?.stdout ?? ""
        guard let entry = entryFromJSON(output: output, name: name) else {
            return .missing
        }
        if entry.running == true {
            return .running
        }
        return .stopped
    }

    private func isOCISource(_ source: String) -> Bool {
        if source.hasPrefix("file://") {
            return false
        }
        return true
    }

    private func hasOCI(source: String) async throws -> Bool {
        let result = try await run(arguments: ["list", "--source", "oci", "--quiet"], wait: true)
        let output = result?.stdout ?? ""
        let expected = normalizeOCI(source)
        return output
            .split(separator: "\n")
            .map { normalizeOCI(String($0)) }
            .contains(expected)
    }

    private func normalizeOCI(_ source: String) -> String {
        let prefix = "oci://"
        if source.hasPrefix(prefix) {
            return String(source.dropFirst(prefix.count))
        }
        return source
    }

    private struct TartListEntry: Decodable {
        let name: String
        let running: Bool?

        private enum CodingKeys: String, CodingKey {
            case name = "Name"
            case running = "Running"
        }
    }

    private func entryFromJSON(output: String, name: String) -> TartListEntry? {
        guard let data = output.data(using: .utf8) else {
            return nil
        }
        guard let entries = try? JSONDecoder().decode([TartListEntry].self, from: data) else {
            return nil
        }
        return entries.first(where: { $0.name == name })
    }


    private func run(arguments: [String], wait: Bool) async throws -> ProcessResult? {
        logger.debug("tart \(arguments.joined(separator: " "))")
        return try await processRunner.run(executable: executable, arguments: arguments, wait: wait)
    }

    private func run(arguments: [String], timeout: Duration) async throws -> ProcessResult {
        logger.debug("tart \(arguments.joined(separator: " "))")
        let handle = try processRunner.startBounded(
            executable: executable,
            arguments: arguments,
            maximumCaptureBytes: 1_024 * 1_024
        )
        return try await waitForProcess(handle, timeout: timeout)
    }
}
