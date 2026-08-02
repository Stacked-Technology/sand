import XCTest
@testable import sand

final class RunnerTests: XCTestCase {
    func testOneShotRunnerDoesNotRestartAfterProvisionerCompletion() {
        XCTAssertFalse(Runner.shouldRestartAfterProvisionerCompletion(stopAfter: 1))
    }

    func testPersistentRunnerRestartsAfterProvisionerCompletion() {
        XCTAssertTrue(Runner.shouldRestartAfterProvisionerCompletion(stopAfter: nil))
    }
}
