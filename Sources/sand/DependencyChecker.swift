import Foundation

struct DependencyChecker {
    static func missingCommands(_ commands: [String]) -> [String] {
        commands.filter { executablePath($0) == nil }
    }

    static func softnetPrivilegesAreConfigured() -> Bool {
        guard let executable = executablePath("softnet") else {
            return false
        }
        let resolvedExecutable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedExecutable),
           let ownerID = attributes[.ownerAccountID] as? NSNumber,
           let permissions = attributes[.posixPermissions] as? NSNumber,
           ownerID.intValue == 0,
           permissions.intValue & 0o4000 != 0 {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["--non-interactive", "--reset-timestamp", resolvedExecutable, "--help"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func executablePath(_ command: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchPaths = pathValue.split(separator: ":").map(String.init)
        for path in searchPaths {
            let candidate = (path as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
