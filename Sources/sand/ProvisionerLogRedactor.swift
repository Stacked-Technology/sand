import Foundation

struct ProvisionerLogRedactor {
    private static let sensitiveOptionPattern = try! NSRegularExpression(
        pattern: #"(?:^|\s)--token(?:\s+|=)(?:"([^"]*)"|'([^']*)'|([^\s]+))"#
    )

    private let sensitiveValues: [String]

    init(command: String) {
        let commandRange = NSRange(command.startIndex..., in: command)
        let matches = Self.sensitiveOptionPattern.matches(in: command, range: commandRange)
        var values: Set<String> = []

        for match in matches {
            for captureIndex in 1 ..< match.numberOfRanges {
                let captureRange = match.range(at: captureIndex)
                guard captureRange.location != NSNotFound,
                      let range = Range(captureRange, in: command)
                else {
                    continue
                }
                let value = String(command[range])
                if !value.isEmpty {
                    values.insert(value)
                }
                break
            }
        }

        sensitiveValues = values.sorted { $0.count > $1.count }
    }

    func redact(_ text: String) -> String {
        sensitiveValues.reduce(text) { redacted, value in
            redacted.replacingOccurrences(of: value, with: "[REDACTED]")
        }
    }

    func redact(_ error: Error) -> Error {
        guard case let ProcessRunnerError.failed(exitCode, stdout, stderr, command) = error else {
            return error
        }
        return ProcessRunnerError.failed(
            exitCode: exitCode,
            stdout: redact(stdout),
            stderr: redact(stderr),
            command: command.map(redact)
        )
    }
}
