import Foundation

struct ConfigValidationIssue: Equatable {
    enum Severity: String {
        case warning
        case error
    }

    let severity: Severity
    let message: String
}

final class ConfigValidator {
    func validate(_ config: Config) -> [ConfigValidationIssue] {
        var issues: [ConfigValidationIssue] = []
        if config.runners.isEmpty {
            issues.append(.init(severity: .error, message: "runners must not be empty."))
            return issues
        }
        issues.append(contentsOf: validateRunners(config.runners))
        return issues
    }

    private func validateRunners(_ runners: [Config.RunnerConfig]) -> [ConfigValidationIssue] {
        var issues: [ConfigValidationIssue] = []
        var seenNames = Set<String>()
        var reservedVMNames = Set<String>()
        var reservedGitHubRunnerNames = Set<String>()

        for runner in runners {
            let trimmedName = runner.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = trimmedName.isEmpty ? "runner <unnamed>" : "runner \(trimmedName)"
            if trimmedName.isEmpty {
                issues.append(.init(severity: .error, message: "runner name must not be empty."))
            } else if trimmedName != runner.name {
                issues.append(.init(
                    severity: .error,
                    message: "runner name must not contain surrounding whitespace."
                ))
            } else if seenNames.contains(trimmedName) {
                issues.append(.init(severity: .error, message: "runner name must be unique: \(trimmedName)."))
            } else {
                seenNames.insert(trimmedName)
            }
            let slotCount = runner.pool?.max ?? 1
            if (1...16).contains(slotCount) {
                for slot in 1...slotCount {
                    let vmName = slot == 1 ? trimmedName : "\(trimmedName)-\(slot)"
                    if !vmName.isEmpty, !reservedVMNames.insert(vmName).inserted {
                        issues.append(.init(
                            severity: .error,
                            message: "runner VM name collides with another configured slot: \(vmName)."
                        ))
                    }
                    if let github = runner.provisioner.github {
                        let baseName = github.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let registrationName = slot == 1 ? baseName : "\(baseName)-\(slot)"
                        if !registrationName.isEmpty,
                           !reservedGitHubRunnerNames.insert(registrationName).inserted {
                            issues.append(.init(
                                severity: .error,
                                message: "GitHub runner name collides with another configured slot: \(registrationName)."
                            ))
                        }
                    }
                }
            }
            if let stopAfter = runner.stopAfter, stopAfter <= 0 {
                issues.append(.init(
                    severity: .warning,
                    message: "\(label): stopAfter is \(stopAfter); sand will exit immediately."
                ))
            }
            var runnerIssues: [ConfigValidationIssue] = []
            if let preRun = runner.preRun, preRun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runnerIssues.append(.init(severity: .error, message: "preRun must not be empty when provided."))
            }
            if let postRun = runner.postRun, postRun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runnerIssues.append(.init(severity: .error, message: "postRun must not be empty when provided."))
            }
            validateVM(runner.vm, issues: &runnerIssues)
            validateProvisioner(runner.provisioner, issues: &runnerIssues)
            if runner.vm.run.guestDNS != nil,
               runner.provisioner.type != .github {
                runnerIssues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS requires a github provisioner so DNS is configured before deferred Softnet isolation."
                ))
            }
            validatePool(runner, issues: &runnerIssues)
            if let healthCheck = runner.healthCheck {
                validateHealthCheck(healthCheck, issues: &runnerIssues)
            }
            validateRunnerCache(runner, issues: &runnerIssues)
            issues.append(contentsOf: runnerIssues.map {
                ConfigValidationIssue(
                    severity: $0.severity,
                    message: "\(label): \($0.message)"
                )
            })
        }

        return issues
    }

    private func validatePool(_ runner: Config.RunnerConfig, issues: inout [ConfigValidationIssue]) {
        guard let pool = runner.pool else {
            return
        }
        guard runner.provisioner.type == .github, let github = runner.provisioner.github else {
            issues.append(.init(severity: .error, message: "pool requires a github provisioner."))
            return
        }
        if !github.ephemeral {
            issues.append(.init(
                severity: .error,
                message: "pool requires provisioner.config.ephemeral: true so every VM accepts only one job."
            ))
        }
        if runner.stopAfter != nil {
            issues.append(.init(
                severity: .error,
                message: "pool owns runner lifecycle; omit stopAfter."
            ))
        }
        if github.repository != nil {
            issues.append(.init(
                severity: .error,
                message: "pool requires organization-level registration; omit provisioner.config.repository."
            ))
        }
        if runner.vm.cache != nil {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.cache to be omitted so jobs cannot persist executable data across ephemeral VMs."
            ))
        }
        if !runner.vm.mounts.isEmpty {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.mounts to be empty so jobs cannot access or persist data on the host."
            ))
        }
        if runner.vm.hardware?.audio != false {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.hardware.audio: false."
            ))
        }
        if !runner.vm.run.noGraphics {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.run.noGraphics: true."
            ))
        }
        if !runner.vm.run.noClipboard {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.run.noClipboard: true."
            ))
        }
        if runner.vm.run.network != .softnet {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.run.network: softnet."
            ))
        }
        let blockTargets = runner.vm.run.softnetBlock.map(SoftnetPolicyTargets.parse) ?? []
        if !blockTargets.contains("@host") {
            issues.append(.init(
                severity: .error,
                message: "pool requires vm.run.softnetBlock to include @host."
            ))
        }
        if pool.min < 0 {
            issues.append(.init(severity: .error, message: "pool.min must not be negative."))
        }
        if pool.max < 1 {
            issues.append(.init(severity: .error, message: "pool.max must be at least 1."))
        }
        if pool.max < pool.min {
            issues.append(.init(severity: .error, message: "pool.max must be greater than or equal to pool.min."))
        }
        if pool.max > 16 {
            issues.append(.init(severity: .error, message: "pool.max must not exceed 16."))
        }
        if pool.pollInterval < 15 {
            issues.append(.init(severity: .error, message: "pool.pollInterval must be at least 15 seconds."))
        }
        if pool.repositories.isEmpty {
            issues.append(.init(severity: .error, message: "pool.repositories must contain at least one repository."))
        }
        var seenRepositories = Set<String>()
        for repository in pool.repositories {
            let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("/") {
                issues.append(.init(
                    severity: .error,
                    message: "pool.repositories entries must be non-empty repository names without '/'."
                ))
            } else if trimmed != repository {
                issues.append(.init(
                    severity: .error,
                    message: "pool.repositories entries must not contain surrounding whitespace."
                ))
            } else if !seenRepositories.insert(trimmed).inserted {
                issues.append(.init(
                    severity: .error,
                    message: "pool.repositories must not contain duplicates: \(trimmed)."
                ))
            }
        }
        if pool.matchLabels.isEmpty {
            issues.append(.init(severity: .error, message: "pool.matchLabels must contain at least one label."))
        }
        let availableLabels = Set(["sand"] + (github.extraLabels ?? []))
        var seenLabels = Set<String>()
        for label in pool.matchLabels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append(.init(severity: .error, message: "pool.matchLabels entries must not be empty."))
            } else if !seenLabels.insert(trimmed).inserted {
                issues.append(.init(
                    severity: .error,
                    message: "pool.matchLabels must not contain duplicates: \(trimmed)."
                ))
            } else if !availableLabels.contains(trimmed) {
                issues.append(.init(
                    severity: .error,
                    message: "pool.matchLabels entry '\(trimmed)' is not registered by the GitHub provisioner."
                ))
            }
        }
    }

    private func validateVM(_ vm: Config.VM, issues: inout [ConfigValidationIssue]) {
        switch vm.source.type {
        case .oci:
            if (vm.source.image ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, message: "vm.source.image is required for OCI sources."))
            }
        case .local:
            let path = stripFilePrefix(vm.source.resolvedSource)
            if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, message: "vm.source.path is required for local sources."))
            } else if !FileManager.default.fileExists(atPath: path) {
                issues.append(.init(severity: .error, message: "Local VM path does not exist: \(path)."))
            }
        }

        if let ramGb = vm.hardware?.ramGb, ramGb <= 0 {
            issues.append(.init(severity: .error, message: "vm.hardware.ramGb must be greater than 0."))
        }
        if let cpuCores = vm.hardware?.cpuCores, cpuCores <= 0 {
            issues.append(.init(severity: .error, message: "vm.hardware.cpuCores must be greater than 0."))
        }
        if let display = vm.hardware?.display {
            if display.width <= 0 || display.height <= 0 {
                issues.append(.init(severity: .error, message: "vm.hardware.display width/height must be greater than 0."))
            }
        }
        if let diskSizeGb = vm.diskSizeGb, diskSizeGb <= 0 {
            issues.append(.init(severity: .error, message: "vm.diskSizeGb must be greater than 0."))
        }
        if let softnetBlock = vm.run.softnetBlock {
            if vm.run.network != .softnet {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.softnetBlock requires vm.run.network: softnet."
                ))
            }
            let targets = SoftnetPolicyTargets.parse(softnetBlock)
            if targets.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.softnetBlock must contain at least one target when provided."
                ))
            } else if SoftnetPolicyTargets.normalized(targets) == nil {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.softnetBlock targets must be IPv4 CIDRs or @host."
                ))
            } else if targets.count > SoftnetPolicyTargets.maximumTargets {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.softnetBlock may contain at most 4096 targets."
                ))
            }
        }
        if let guestDNS = vm.run.guestDNS {
            if vm.run.network != .softnet {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS requires vm.run.network: softnet."
                ))
            }
            if vm.run.softnetBlock == nil {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS requires vm.run.softnetBlock so DNS is probed after policy cutover."
                ))
            }
            let networkService = guestDNS.networkService.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if networkService.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.networkService must not be empty."
                ))
            } else if networkService != guestDNS.networkService {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.networkService must not contain surrounding whitespace."
                ))
            }
            if guestDNS.servers.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.servers must contain at least one IPv4 address."
                ))
            } else if guestDNS.servers.count > 3 {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.servers must contain at most three IPv4 addresses."
                ))
            } else if SoftnetPolicyTargets.normalized(
                guestDNS.servers.map { "\($0)/32" }
            ) == nil {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.servers entries must be IPv4 addresses."
                ))
            } else if guestDNS.servers.contains(where: {
                !SoftnetPolicyTargets.isGloballyRoutableIPv4($0)
            }) {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.servers entries must be globally routable IPv4 addresses."
                ))
            } else if Set(guestDNS.servers).count != guestDNS.servers.count {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.servers must not contain duplicates."
                ))
            } else if let block = vm.run.softnetBlock {
                let blockTargets = SoftnetPolicyTargets.parse(block)
                if guestDNS.servers.contains(where: { server in
                    blockTargets.contains {
                        SoftnetPolicyTargets.contains(
                            address: server,
                            target: $0
                        )
                    }
                }) {
                    issues.append(.init(
                        severity: .error,
                        message: "vm.run.guestDNS.servers must not overlap vm.run.softnetBlock targets."
                    ))
                }
            }
            let probeHost = guestDNS.probeHost.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if probeHost.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.probeHost must not be empty."
                ))
            } else if probeHost != guestDNS.probeHost {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.probeHost must not contain surrounding whitespace."
                ))
            } else if !Self.isDNSProbeHostname(probeHost) {
                issues.append(.init(
                    severity: .error,
                    message: "vm.run.guestDNS.probeHost must be a non-local fully qualified DNS hostname."
                ))
            }
        }

        if vm.ssh.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, message: "vm.ssh.user must not be empty."))
        }
        if vm.ssh.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, message: "vm.ssh.password must not be empty."))
        }
        if vm.ssh.port <= 0 || vm.ssh.port > 65_535 {
            issues.append(.init(severity: .error, message: "vm.ssh.port must be between 1 and 65535."))
        }
        if let connectMaxRetries = vm.ssh.connectMaxRetries, connectMaxRetries <= 0 {
            issues.append(.init(severity: .error, message: "vm.ssh.connectMaxRetries must be greater than 0."))
        }

        for mount in vm.mounts {
            let hostPath = mount.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if hostPath.isEmpty {
                issues.append(.init(severity: .error, message: "vm.mounts.host must not be empty."))
            } else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), !isDirectory.boolValue {
                    issues.append(.init(severity: .error, message: "vm.mounts.host must be a directory: \(hostPath)."))
                }
            }
            let resolvedName = Config.resolveMountName(hostPath: mount.hostPath, name: mount.name)
            validateMountName(resolvedName, label: "vm.mounts.name", issues: &issues)
        }
    }

    private static func isDNSProbeHostname(_ value: String) -> Bool {
        let lowercaseValue = value.lowercased()
        guard value.count <= 253,
              value.contains("."),
              SoftnetPolicyTargets.normalized(["\(value)/32"]) == nil,
              !lowercaseValue.hasSuffix(".local"),
              !lowercaseValue.hasSuffix(".localhost"),
              !lowercaseValue.hasSuffix(".test"),
              !lowercaseValue.hasSuffix(".invalid"),
              !lowercaseValue.hasSuffix(".example") else {
            return false
        }
        let labels = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return label.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
            }
        }
    }

    private func validateHealthCheck(_ healthCheck: Config.HealthCheck, issues: inout [ConfigValidationIssue]) {
        if healthCheck.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, message: "healthCheck.command must not be empty."))
        }
        if healthCheck.interval <= 0 {
            issues.append(.init(severity: .error, message: "healthCheck.interval must be greater than 0."))
        }
        if healthCheck.delay < 0 {
            issues.append(.init(severity: .error, message: "healthCheck.delay must be greater than or equal to 0."))
        }
    }

    private func validateProvisioner(_ provisioner: Config.Provisioner, issues: inout [ConfigValidationIssue]) {
        switch provisioner.type {
        case .script:
            let script = provisioner.script?.run.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if script.isEmpty {
                issues.append(.init(severity: .error, message: "provisioner.config.run must not be empty for script provisioner."))
            }
        case .github:
            guard let github = provisioner.github else {
                issues.append(.init(severity: .error, message: "provisioner.config is required for github provisioner."))
                return
            }
            if github.appId <= 0 {
                issues.append(.init(severity: .error, message: "provisioner.config.appId must be greater than 0."))
            }
            let runnerName = github.runnerName.trimmingCharacters(in: .whitespacesAndNewlines)
            if runnerName != github.runnerName {
                issues.append(.init(
                    severity: .error,
                    message: "provisioner.config.runnerName must not contain surrounding whitespace."
                ))
            }
            if github.organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, message: "provisioner.config.organization must not be empty."))
            }
            if github.runnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, message: "provisioner.config.runnerName must not be empty."))
            }
            if let runnerGroup = github.runnerGroup, runnerGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, message: "provisioner.config.runnerGroup must not be empty when set."))
            }
            if github.runnerGroup != nil, github.repository != nil {
                issues.append(.init(
                    severity: .error,
                    message: "provisioner.config.runnerGroup requires organization-level registration; omit provisioner.config.repository."
                ))
            }
            let keyPath = github.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if keyPath.isEmpty {
                issues.append(.init(severity: .error, message: "provisioner.config.privateKeyPath must not be empty."))
            } else if !FileManager.default.fileExists(atPath: keyPath) {
                issues.append(.init(severity: .error, message: "Private key not found at \(keyPath)."))
            }
            if let repository = github.repository, repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .warning, message: "provisioner.config.repository is set but empty."))
            }
        }
    }

    private func validateRunnerCache(_ runner: Config.RunnerConfig, issues: inout [ConfigValidationIssue]) {
        guard let cache = runner.vm.cache else {
            if runner.provisioner.type == .github, runner.pool == nil {
                issues.append(.init(
                    severity: .warning,
                    message: "github provisioner configured without vm.cache; runner cache is disabled."
                ))
            }
            return
        }
        if runner.provisioner.type != .github {
            issues.append(.init(
                severity: .warning,
                message: "vm.cache is set but provisioner is not github; cache will be ignored."
            ))
        }
        let hostPath = cache.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if hostPath.isEmpty {
            issues.append(.init(severity: .error, message: "vm.cache.host must not be empty."))
        } else {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory), !isDirectory.boolValue {
                issues.append(.init(
                    severity: .error,
                    message: "vm.cache.host must be a directory: \(hostPath)."
                ))
            }
        }
        let resolvedName = Config.resolveMountName(hostPath: cache.hostPath, name: cache.name)
        validateMountName(resolvedName, label: "vm.cache.name", issues: &issues)
    }

    private func stripFilePrefix(_ path: String) -> String {
        let prefix = "file://"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private func validateMountName(_ name: String, label: String, issues: inout [ConfigValidationIssue]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            issues.append(.init(severity: .error, message: "\(label) must not be empty."))
            return
        }
        if trimmed.contains("/") {
            issues.append(.init(severity: .error, message: "\(label) must not contain '/'."))
        }
        if trimmed.contains(":") {
            issues.append(.init(severity: .error, message: "\(label) must not contain ':'."))
        }
    }
}
