import Darwin
import Foundation

enum SoftnetPolicyTargets {
    static let maximumTargets = 4_096

    static func parse(_ value: String) -> [String] {
        value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalized(_ targets: [String]) -> [String]? {
        var normalizedTargets: [String] = []
        normalizedTargets.reserveCapacity(targets.count)
        for target in targets {
            guard let normalizedTarget = normalize(target) else {
                return nil
            }
            normalizedTargets.append(normalizedTarget)
        }
        return Array(Set(normalizedTargets)).sorted()
    }

    private static func normalize(_ target: String) -> String? {
        if target == "@host" {
            return target
        }
        let components = target.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let prefixLength = Int(components[1]),
              (0...32).contains(prefixLength) else {
            return nil
        }
        var address = in_addr()
        guard String(components[0]).withCString({
            inet_pton(AF_INET, $0, &address)
        }) == 1 else {
            return nil
        }
        let hostOrderAddress = UInt32(bigEndian: address.s_addr)
        let mask = prefixLength == 0
            ? UInt32(0)
            : UInt32.max << UInt32(32 - prefixLength)
        var networkAddress = in_addr(
            s_addr: (hostOrderAddress & mask).bigEndian
        )
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(
            AF_INET,
            &networkAddress,
            &buffer,
            socklen_t(buffer.count)
        ) != nil else {
            return nil
        }
        let addressString = String(
            decoding: buffer
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return "\(addressString)/\(prefixLength)"
    }
}

protocol SoftnetPolicyControlling: Sendable {
    func replacePolicy(allow: [String], block: [String]) async throws
}

enum SoftnetPolicyControlError: Error {
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case childDescriptorUnavailable
    case requestFailed(Int32)
    case responseClosed
    case responseTooLarge
    case invalidResponse
    case policyRejected(String)
    case tooManyTargets
}

actor SoftnetPolicyControl: SoftnetPolicyControlling {
    private static let requestID = "sand-network-cutover"
    private static let maximumResponseBytes = 1_048_576

    nonisolated let inheritedDescriptor: Int32
    private var controlDescriptor: Int32
    private var inheritedDescriptorOpen = true
    private var controlDescriptorOpen = true

    init(timeoutSeconds: Int = 5) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SoftnetPolicyControlError.socketCreationFailed(errno)
        }
        controlDescriptor = descriptors[0]
        inheritedDescriptor = descriptors[1]

        do {
            try Self.configureControlDescriptor(
                controlDescriptor,
                timeoutSeconds: timeoutSeconds
            )
            try Self.setCloseOnExec(controlDescriptor, enabled: true)
            try Self.setCloseOnExec(inheritedDescriptor, enabled: false)
        } catch {
            Darwin.close(controlDescriptor)
            Darwin.close(inheritedDescriptor)
            throw error
        }
    }

    deinit {
        if controlDescriptorOpen {
            Darwin.close(controlDescriptor)
        }
        if inheritedDescriptorOpen {
            Darwin.close(inheritedDescriptor)
        }
    }

    func childDidLaunch() {
        guard inheritedDescriptorOpen else {
            return
        }
        Darwin.close(inheritedDescriptor)
        inheritedDescriptorOpen = false
    }

    func close() {
        if inheritedDescriptorOpen {
            Darwin.close(inheritedDescriptor)
            inheritedDescriptorOpen = false
        }
        if controlDescriptorOpen {
            Darwin.close(controlDescriptor)
            controlDescriptorOpen = false
        }
    }

    func replacePolicy(allow: [String], block: [String]) async throws {
        guard controlDescriptorOpen else {
            throw SoftnetPolicyControlError.responseClosed
        }
        guard allow.count + block.count <= SoftnetPolicyTargets.maximumTargets else {
            throw SoftnetPolicyControlError.tooManyTargets
        }
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Self.requestID,
            "method": "softnet.policy.set",
            "params": [
                "allow": allow,
                "block": block
            ]
        ]
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        try sendAll(payload)
        let responseData = try receiveLine()
        let rawResponse = try JSONSerialization.jsonObject(with: responseData)
        guard let response = rawResponse as? [String: Any],
              response["jsonrpc"] as? String == "2.0",
              response["id"] as? String == Self.requestID else {
            throw SoftnetPolicyControlError.invalidResponse
        }
        if let error = response["error"] {
            throw SoftnetPolicyControlError.policyRejected(String(describing: error))
        }
        guard let result = response["result"] as? [String: Any],
              let appliedAllow = result["allow"] as? [String],
              let appliedBlock = result["block"] as? [String],
              let requestedAllow = SoftnetPolicyTargets.normalized(allow),
              let requestedBlock = SoftnetPolicyTargets.normalized(block),
              let normalizedAppliedAllow = SoftnetPolicyTargets.normalized(appliedAllow),
              let normalizedAppliedBlock = SoftnetPolicyTargets.normalized(appliedBlock),
              normalizedAppliedAllow == requestedAllow,
              normalizedAppliedBlock == requestedBlock else {
            throw SoftnetPolicyControlError.invalidResponse
        }
    }

    private func sendAll(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { bytes in
                Darwin.send(
                    controlDescriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset,
                    0
                )
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if sent < 0, errno == EINTR {
                continue
            }
            throw SoftnetPolicyControlError.requestFailed(errno)
        }
    }

    private func receiveLine() throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let received = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(
                    controlDescriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0
                )
            }
            if received > 0 {
                response.append(contentsOf: buffer.prefix(received))
                if let newline = response.firstIndex(of: 0x0A) {
                    guard newline <= Self.maximumResponseBytes else {
                        throw SoftnetPolicyControlError.responseTooLarge
                    }
                    return response.prefix(upTo: newline)
                }
                guard response.count <= Self.maximumResponseBytes else {
                    throw SoftnetPolicyControlError.responseTooLarge
                }
                continue
            }
            if received == 0 {
                throw SoftnetPolicyControlError.responseClosed
            }
            if errno == EINTR {
                continue
            }
            throw SoftnetPolicyControlError.requestFailed(errno)
        }
    }

    private static func configureControlDescriptor(
        _ descriptor: Int32,
        timeoutSeconds: Int
    ) throws {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            timeoutSize
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            timeoutSize
        ) == 0 else {
            throw SoftnetPolicyControlError.socketConfigurationFailed(errno)
        }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw SoftnetPolicyControlError.socketConfigurationFailed(errno)
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32, enabled: Bool) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else {
            throw SoftnetPolicyControlError.socketConfigurationFailed(errno)
        }
        let updated = enabled ? flags | FD_CLOEXEC : flags & ~FD_CLOEXEC
        guard fcntl(descriptor, F_SETFD, updated) == 0 else {
            throw SoftnetPolicyControlError.socketConfigurationFailed(errno)
        }
    }
}
