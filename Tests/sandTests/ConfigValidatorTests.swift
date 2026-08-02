import Foundation
import XCTest
@testable import sand

final class ConfigValidatorTests: XCTestCase {
    func testValidConfigHasNoIssues() throws {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: "sand-cache"),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: Config.HealthCheck(command: "true")
        )
        let config = Config(runners: [runner])
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.isEmpty)
    }

    func testInvalidConfigReportsIssues() {
        let vm = Config.VM(
            source: Config.VMSource(type: .local, image: nil, path: "/missing-vm"),
            hardware: Config.Hardware(
                ramGb: 0,
                cpuCores: 0,
                display: Config.Display(width: 0, height: 0, unit: nil, refit: nil),
                audio: nil
            ),
            mounts: [Config.DirectoryMount(hostPath: "/missing-mount", name: "bad/name", mode: .rw)],
            cache: nil,
            run: .default,
            diskSizeGb: 0,
            ssh: Config.SSH(user: "", password: "", port: 70_000, connectMaxRetries: 0)
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .script, script: .init(run: "  "), github: nil),
            preRun: nil,
            postRun: nil,
            stopAfter: 0,
            healthCheck: Config.HealthCheck(command: "  ", interval: 0, delay: -1)
        )
        let config = Config(runners: [runner])
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .warning, message: "runner runner-1: stopAfter is 0; sand will exit immediately.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: Local VM path does not exist: /missing-vm.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.hardware.ramGb must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.hardware.cpuCores must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.hardware.display width/height must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.diskSizeGb must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.user must not be empty.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.password must not be empty.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.port must be between 1 and 65535.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.ssh.connectMaxRetries must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: vm.mounts.name must not contain '/'.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: provisioner.config.run must not be empty for script provisioner.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: healthCheck.command must not be empty.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: healthCheck.interval must be greater than 0.")))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner runner-1: healthCheck.delay must be greater than or equal to 0.")))
    }

    func testDuplicateRunnerNamesAreRejected() {
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: nil,
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let provisioner = Config.Provisioner(type: .script, script: .init(run: "echo hi"), github: nil)
        let runners = [
            Config.RunnerConfig(name: "same", vm: vm, provisioner: provisioner, preRun: nil, postRun: nil, stopAfter: nil, healthCheck: nil),
            Config.RunnerConfig(name: "same", vm: vm, provisioner: provisioner, preRun: nil, postRun: nil, stopAfter: nil, healthCheck: nil)
        ]
        let config = Config(runners: runners)
        let issues = ConfigValidator().validate(config)
        XCTAssertTrue(issues.contains(ConfigValidationIssue(severity: .error, message: "runner name must be unique: same.")))
    }

    func testSoftnetBlockRequiresSoftnetAndAValue() throws {
        let nonSoftnetURL = try writeTempFile(contents: """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
              run:
                network: default
                softnetBlock: "@host"
            provisioner:
              type: script
              config:
                run: "echo ok"
        """)
        let emptyBlockURL = try writeTempFile(contents: """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
              run:
                network: softnet
                softnetBlock: " "
            provisioner:
              type: script
              config:
                run: "echo ok"
        """)
        let delimiterBlockURL = try writeTempFile(contents: """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
              run:
                network: softnet
                softnetBlock: ", ,"
            provisioner:
              type: script
              config:
                run: "echo ok"
        """)
        let invalidBlockURL = try writeTempFile(contents: """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
              run:
                network: softnet
                softnetBlock: "10.0.0.0/99"
            provisioner:
              type: script
              config:
                run: "echo ok"
        """)
        let oversizedTargets = Array(
            repeating: "@host",
            count: SoftnetPolicyTargets.maximumTargets + 1
        ).joined(separator: ",")
        let oversizedBlockURL = try writeTempFile(contents: """
        runners:
          - name: runner-1
            vm:
              source:
                type: oci
                image: ghcr.io/acme/vm:latest
              run:
                network: softnet
                softnetBlock: "\(oversizedTargets)"
            provisioner:
              type: script
              config:
                run: "echo ok"
        """)

        let nonSoftnetIssues = ConfigValidator().validate(
            try Config.load(path: nonSoftnetURL.path)
        )
        XCTAssertTrue(nonSoftnetIssues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.run.softnetBlock requires vm.run.network: softnet."
        )))
        let emptyBlockIssues = ConfigValidator().validate(
            try Config.load(path: emptyBlockURL.path)
        )
        XCTAssertTrue(emptyBlockIssues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.run.softnetBlock must contain at least one target when provided."
        )))
        let delimiterBlockIssues = ConfigValidator().validate(
            try Config.load(path: delimiterBlockURL.path)
        )
        XCTAssertTrue(delimiterBlockIssues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.run.softnetBlock must contain at least one target when provided."
        )))
        let invalidBlockIssues = ConfigValidator().validate(
            try Config.load(path: invalidBlockURL.path)
        )
        XCTAssertTrue(invalidBlockIssues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.run.softnetBlock targets must be IPv4 CIDRs or @host."
        )))
        let oversizedBlockIssues = ConfigValidator().validate(
            try Config.load(path: oversizedBlockURL.path)
        )
        XCTAssertTrue(oversizedBlockIssues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.run.softnetBlock may contain at most 4096 targets."
        )))
    }

    func testGuestDNSRejectsUnsafeAndInvalidConfiguration() throws {
        let cases: [(runConfig: String, expected: String)] = [
            (
                """
                network: default
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1]
                """,
                "vm.run.guestDNS requires vm.run.network: softnet."
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1]
                """,
                "vm.run.guestDNS requires vm.run.softnetBlock"
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: " "
                  servers: [1.1.1.1]
                """,
                "vm.run.guestDNS.networkService must not be empty."
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: Ethernet
                  servers: []
                """,
                "vm.run.guestDNS.servers must contain at least one IPv4 address."
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: Ethernet
                  servers: [not-an-address]
                """,
                "vm.run.guestDNS.servers entries must be IPv4 addresses."
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: Ethernet
                  servers: [192.168.2.1]
                """,
                "vm.run.guestDNS.servers entries must be globally routable IPv4 addresses."
            ),
            (
                """
                network: softnet
                softnetBlock: "@host"
                guestDNS:
                  networkService: Ethernet
                  servers: [203.0.113.53]
                """,
                "vm.run.guestDNS.servers entries must be globally routable IPv4 addresses."
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1, 1.1.1.1]
                """,
                "vm.run.guestDNS.servers must not contain duplicates."
            ),
            (
                """
                network: softnet
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1, 8.8.8.8, 9.9.9.9, 8.8.4.4]
                """,
                "vm.run.guestDNS.servers must contain at most three IPv4 addresses."
            ),
            (
                """
                network: softnet
                softnetBlock: "1.1.1.0/24,@host"
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1]
                """,
                "vm.run.guestDNS.servers must not overlap vm.run.softnetBlock targets."
            ),
            (
                """
                network: softnet
                softnetBlock: "@host"
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1]
                  probeHost: foo.localhost
                """,
                "vm.run.guestDNS.probeHost must be a non-local fully qualified DNS hostname."
            ),
            (
                """
                network: softnet
                softnetBlock: "@host"
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1]
                  probeHost: 127.0.0.1
                """,
                "vm.run.guestDNS.probeHost must be a non-local fully qualified DNS hostname."
            ),
            (
                """
                network: softnet
                softnetBlock: "@host"
                guestDNS:
                  networkService: Ethernet
                  servers: [1.1.1.1]
                  probeHost: runner.test
                """,
                "vm.run.guestDNS.probeHost must be a non-local fully qualified DNS hostname."
            )
        ]

        for testCase in cases {
            let url = try writeTempFile(contents: """
            runners:
              - name: runner-1
                vm:
                  source:
                    type: oci
                    image: ghcr.io/acme/vm:latest
                  run:
            \(testCase.runConfig.split(separator: "\n").map { "        \($0)" }.joined(separator: "\n"))
                provisioner:
                  type: script
                  config:
                    run: "echo ok"
            """)
            let issues = ConfigValidator().validate(try Config.load(path: url.path))
            XCTAssertTrue(
                issues.contains {
                    $0.severity == .error && $0.message.contains(testCase.expected)
                },
                "missing expected issue: \(testCase.expected); got \(issues)"
            )
            XCTAssertTrue(
                issues.contains {
                    $0.severity == .error
                        && $0.message.contains("guestDNS requires a github provisioner")
                },
                "guestDNS must reject script provisioners; got \(issues)"
            )
        }
    }

    func testEmptyRunnerGroupIsRejected() throws {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: "sand-cache"),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: nil,
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: "  "
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: Config.HealthCheck(command: "true")
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.runnerGroup must not be empty when set."
        )))
    }

    func testRunnerGroupWithRepositoryIsRejected() throws {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: "/tmp/sand-cache", name: "sand-cache"),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: "repo",
            privateKeyPath: keyURL.path,
            runnerName: "runner-1",
            extraLabels: nil,
            runnerGroup: "mac-runners"
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: 1,
            healthCheck: Config.HealthCheck(command: "true")
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: provisioner.config.runnerGroup requires organization-level registration; omit provisioner.config.repository."
        )))
    }

    func testRunnerCacheValidation() throws {
        let cacheFile = try writeTempFile(contents: "not-a-directory")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: nil,
            mounts: [],
            cache: Config.Cache(hostPath: cacheFile.path, name: "bad/cache"),
            run: .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let runner = Config.RunnerConfig(
            name: "runner-1",
            vm: vm,
            provisioner: Config.Provisioner(type: .script, script: .init(run: "echo ok"), github: nil),
            preRun: nil,
            postRun: nil,
            stopAfter: nil,
            healthCheck: nil
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .warning,
            message: "runner runner-1: vm.cache is set but provisioner is not github; cache will be ignored."
        )))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.cache.name must not contain '/'."
        )))
        XCTAssertTrue(issues.contains(ConfigValidationIssue(
            severity: .error,
            message: "runner runner-1: vm.cache.host must be a directory: \(cacheFile.path)."
        )))
    }

    func testValidRunnerPoolHasNoErrors() throws {
        let runner = try makePoolRunner(
            pool: Config.RunnerPool(
                min: 1,
                max: 2,
                pollInterval: 15,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    func testColdStartRunnerPoolAllowsZeroWarmRunners() throws {
        let runner = try makePoolRunner(
            pool: Config.RunnerPool(
                min: 0,
                max: 1,
                pollInterval: 15,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    func testRunnerPoolRequiresAtLeastOneCapacitySlot() throws {
        let runner = try makePoolRunner(
            pool: Config.RunnerPool(
                min: 0,
                max: 0,
                pollInterval: 15,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let messages = ConfigValidator()
            .validate(Config(runners: [runner]))
            .map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("pool.max must be at least 1") })
    }

    func testRunnerPoolRejectsNegativeWarmMinimum() throws {
        let runner = try makePoolRunner(
            pool: Config.RunnerPool(
                min: -1,
                max: 1,
                pollInterval: 15,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let messages = ConfigValidator()
            .validate(Config(runners: [runner]))
            .map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("pool.min must not be negative") })
    }

    func testRunnerPoolRejectsUnsafeAndInvalidConfiguration() throws {
        let runner = try makePoolRunner(
            repository: "repo",
            ephemeral: false,
            stopAfter: 1,
            mountsHost: true,
            pool: Config.RunnerPool(
                min: 0,
                max: 17,
                pollInterval: 1,
                repositories: ["", "owner/repo", "repo", "repo", " padded "],
                matchLabels: ["", "missing", "missing"]
            )
        )
        let issues = ConfigValidator().validate(Config(runners: [runner]))
        let messages = issues.map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("pool requires provisioner.config.ephemeral: true") })
        XCTAssertTrue(messages.contains { $0.contains("pool owns runner lifecycle; omit stopAfter") })
        XCTAssertTrue(messages.contains { $0.contains("pool requires organization-level registration") })
        XCTAssertTrue(messages.contains { $0.contains("pool requires vm.cache to be omitted") })
        XCTAssertTrue(messages.contains { $0.contains("pool requires vm.mounts to be empty") })
        XCTAssertTrue(messages.contains { $0.contains("pool.max must not exceed 16") })
        XCTAssertTrue(messages.contains { $0.contains("pool.pollInterval must be at least 15 seconds") })
        XCTAssertTrue(messages.contains { $0.contains("pool.repositories entries must be non-empty") })
        XCTAssertTrue(messages.contains { $0.contains("pool.repositories entries must not contain surrounding whitespace") })
        XCTAssertTrue(messages.contains { $0.contains("pool.repositories must not contain duplicates: repo") })
        XCTAssertTrue(messages.contains { $0.contains("pool.matchLabels entries must not be empty") })
        XCTAssertTrue(messages.contains { $0.contains("pool.matchLabels entry 'missing' is not registered") })
        XCTAssertTrue(messages.contains { $0.contains("pool.matchLabels must not contain duplicates: missing") })
    }

    func testRunnerPoolRejectsUnisolatedVMOptions() throws {
        let runner = try makePoolRunner(
            isolatedVM: false,
            pool: Config.RunnerPool(
                max: 2,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let messages = ConfigValidator()
            .validate(Config(runners: [runner]))
            .map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("vm.hardware.audio: false") })
        XCTAssertTrue(messages.contains { $0.contains("vm.run.noClipboard: true") })
        XCTAssertTrue(messages.contains { $0.contains("vm.run.network: softnet") })
        XCTAssertTrue(messages.contains { $0.contains("vm.run.softnetBlock to include @host") })
    }

    func testRunnerPoolRejectsWhitespaceNamesAndHugeMaximum() throws {
        let runner = try makePoolRunner(
            name: " runner ",
            runnerName: " registration ",
            pool: Config.RunnerPool(
                max: Int.max,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let messages = ConfigValidator()
            .validate(Config(runners: [runner]))
            .map(\.message)
        XCTAssertTrue(messages.contains {
            $0.contains("runner name must not contain surrounding whitespace")
        })
        XCTAssertTrue(messages.contains {
            $0.contains("provisioner.config.runnerName must not contain surrounding whitespace")
        })
        XCTAssertTrue(messages.contains { $0.contains("pool.max must not exceed 16") })
    }

    func testRunnerPoolRejectsGeneratedVMAndGitHubNameCollisions() throws {
        let poolRunner = try makePoolRunner(
            name: "runner",
            runnerName: "registration",
            pool: Config.RunnerPool(
                max: 2,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let collidingRunner = try makePoolRunner(
            name: "runner-2",
            runnerName: "registration-2",
            pool: Config.RunnerPool(
                max: 1,
                repositories: ["mobile"],
                matchLabels: ["macos-pool"]
            )
        )
        let messages = ConfigValidator()
            .validate(Config(runners: [poolRunner, collidingRunner]))
            .map(\.message)
        XCTAssertTrue(messages.contains {
            $0.contains("runner VM name collides with another configured slot: runner-2")
        })
        XCTAssertTrue(messages.contains {
            $0.contains("GitHub runner name collides with another configured slot: registration-2")
        })
    }

    private func makePoolRunner(
        name: String = "runner-pool",
        runnerName: String = "runner-pool",
        repository: String? = nil,
        ephemeral: Bool = true,
        stopAfter: Int? = nil,
        mountsHost: Bool = false,
        isolatedVM: Bool = true,
        pool: Config.RunnerPool
    ) throws -> Config.RunnerConfig {
        let keyURL = try writeTempFile(contents: "key", suffix: ".pem")
        let vm = Config.VM(
            source: Config.VMSource(type: .oci, image: "ghcr.io/acme/vm:latest", path: nil),
            hardware: Config.Hardware(
                ramGb: nil,
                cpuCores: nil,
                display: nil,
                audio: isolatedVM ? false : nil
            ),
            mounts: mountsHost
                ? [Config.DirectoryMount(hostPath: "/tmp", name: "host", mode: .rw)]
                : [],
            cache: repository == "repo"
                ? Config.Cache(hostPath: "/tmp/sand-cache", name: "sand-cache")
                : nil,
            run: isolatedVM
                ? Config.RunOptions(
                    noGraphics: true,
                    noClipboard: true,
                    network: .softnet,
                    softnetBlock: "@host",
                    guestDNS: Config.RunOptions.GuestDNS(
                        networkService: "Ethernet",
                        servers: ["1.1.1.1", "8.8.8.8"]
                    )
                )
                : .default,
            diskSizeGb: nil,
            ssh: .standard
        )
        let github = GitHubProvisionerConfig(
            appId: 1,
            organization: "acme",
            repository: repository,
            privateKeyPath: keyURL.path,
            runnerName: runnerName,
            ephemeral: ephemeral,
            extraLabels: ["macos-pool"]
        )
        return Config.RunnerConfig(
            name: name,
            vm: vm,
            provisioner: Config.Provisioner(type: .github, script: nil, github: github),
            preRun: nil,
            postRun: nil,
            stopAfter: stopAfter,
            healthCheck: Config.HealthCheck(command: "true"),
            pool: pool
        )
    }
}
