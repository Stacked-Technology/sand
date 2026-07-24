import Darwin
import Foundation
import XCTest
@testable import sand

final class SoftnetPolicyControlTests: XCTestCase {
    func testReplacePolicyRejectsMoreThanSoftnetTargetLimit() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 1)
        let targets = Array(
            repeating: "@host",
            count: SoftnetPolicyTargets.maximumTargets + 1
        )

        do {
            try await control.replacePolicy(allow: [], block: targets)
            XCTFail("Expected oversized policy to fail before transmission")
        } catch SoftnetPolicyControlError.tooManyTargets {
            // Mirrors Softnet's documented combined allow/block target limit.
        }
    }

    func testReplacePolicyAcceptsMaximumSizedAcknowledgement() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 2)
        let peerDescriptor = dup(control.inheritedDescriptor)
        XCTAssertGreaterThanOrEqual(peerDescriptor, 0)
        await control.childDidLaunch()
        let targets = (0..<SoftnetPolicyTargets.maximumTargets).map { index in
            "10.\((index >> 8) & 0xFF).\(index & 0xFF).1/32"
        }
        let responseObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "sand-network-cutover",
            "result": [
                "allow": [],
                "block": targets,
                "ruleCount": targets.count
            ]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        XCTAssertGreaterThan(responseData.count, 65_536)
        startPeer(
            descriptor: peerDescriptor,
            requestBox: LockedDataBox(),
            response: String(decoding: responseData, as: UTF8.self)
        )

        try await control.replacePolicy(allow: [], block: targets)
    }

    func testReplacePolicyRejectsOversizedNewlineTerminatedResponse() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 2)
        let peerDescriptor = dup(control.inheritedDescriptor)
        XCTAssertGreaterThanOrEqual(peerDescriptor, 0)
        await control.childDidLaunch()
        startPeer(
            descriptor: peerDescriptor,
            requestBox: LockedDataBox(),
            response: String(repeating: "x", count: 1_048_577)
        )

        do {
            try await control.replacePolicy(allow: [], block: ["@host"])
            XCTFail("Expected oversized response to fail at the framing boundary")
        } catch SoftnetPolicyControlError.responseTooLarge {
            // A newline in the final read must not bypass the response-size cap.
        }
    }


    func testReplacePolicyWaitsForMatchingAcknowledgement() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 1)
        let peerDescriptor = dup(control.inheritedDescriptor)
        XCTAssertGreaterThanOrEqual(peerDescriptor, 0)
        await control.childDidLaunch()
        let requestBox = LockedDataBox()
        startPeer(
            descriptor: peerDescriptor,
            requestBox: requestBox,
            response: """
            {"jsonrpc":"2.0","id":"sand-network-cutover","result":{"allow":[],"block":["@host"],"ruleCount":1}}
            """
        )

        try await control.replacePolicy(allow: [], block: ["@host"])

        let requestData = requestBox.value()
        let request = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertEqual(request["method"] as? String, "softnet.policy.set")
        let parameters = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(parameters["allow"] as? [String], [])
        XCTAssertEqual(parameters["block"] as? [String], ["@host"])
    }

    func testReplacePolicyRejectsMismatchedAcknowledgement() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 1)
        let peerDescriptor = dup(control.inheritedDescriptor)
        XCTAssertGreaterThanOrEqual(peerDescriptor, 0)
        await control.childDidLaunch()
        startPeer(
            descriptor: peerDescriptor,
            requestBox: LockedDataBox(),
            response: """
            {"jsonrpc":"2.0","id":"other-request","result":{"allow":[],"block":["@host"],"ruleCount":1}}
            """
        )

        do {
            try await control.replacePolicy(allow: [], block: ["@host"])
            XCTFail("Expected mismatched acknowledgement to fail")
        } catch SoftnetPolicyControlError.invalidResponse {
            // The runner must not start unless Softnet acknowledges this exact request.
        }
    }

    func testReplacePolicyAcceptsCanonicalizedCIDRAcknowledgement() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 1)
        let peerDescriptor = dup(control.inheritedDescriptor)
        XCTAssertGreaterThanOrEqual(peerDescriptor, 0)
        await control.childDidLaunch()
        startPeer(
            descriptor: peerDescriptor,
            requestBox: LockedDataBox(),
            response: """
            {"jsonrpc":"2.0","id":"sand-network-cutover","result":{"allow":[],"block":["10.0.0.0/8"],"ruleCount":1}}
            """
        )

        try await control.replacePolicy(allow: [], block: ["10.1.2.3/8"])
    }

    func testReplacePolicyRejectsDifferentCIDRWithSameRuleCount() async throws {
        let control = try SoftnetPolicyControl(timeoutSeconds: 1)
        let peerDescriptor = dup(control.inheritedDescriptor)
        XCTAssertGreaterThanOrEqual(peerDescriptor, 0)
        await control.childDidLaunch()
        startPeer(
            descriptor: peerDescriptor,
            requestBox: LockedDataBox(),
            response: """
            {"jsonrpc":"2.0","id":"sand-network-cutover","result":{"allow":[],"block":["192.168.0.0/16"],"ruleCount":1}}
            """
        )

        do {
            try await control.replacePolicy(allow: [], block: ["10.0.0.0/8"])
            XCTFail("Expected different CIDR acknowledgement to fail")
        } catch SoftnetPolicyControlError.invalidResponse {
            // Equal rule counts do not prove that the requested policy was applied.
        }
    }

    private func startPeer(
        descriptor: Int32,
        requestBox: LockedDataBox,
        response: String
    ) {
        DispatchQueue.global().async {
            defer {
                Darwin.close(descriptor)
            }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else {
                    break
                }
                request.append(contentsOf: buffer.prefix(count))
                if let newline = request.firstIndex(of: 0x0A) {
                    request = request.prefix(upTo: newline)
                    break
                }
            }
            requestBox.set(request)
            let payload = Array((response + "\n").utf8)
            payload.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        return
                    }
                    offset += written
                }
            }
        }
    }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer {
            lock.unlock()
        }
        return data
    }
}
