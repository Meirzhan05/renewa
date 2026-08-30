import XCTest
@testable import Renewa

@MainActor
final class InboxScanPollingPolicyTests: XCTestCase {
    func test_pollingDelay_staysFastForInitialWindow_thenPacesLongScan() {
        XCTAssertEqual(InboxScanPollingPolicy.delayAfterSuccessfulPoll(0), .seconds(2))
        XCTAssertEqual(
            InboxScanPollingPolicy.delayAfterSuccessfulPoll(InboxScanPollingPolicy.fastPollCount),
            .seconds(12)
        )
    }

    func test_retryDelay_isBoundedAndNeverImmediate() {
        XCTAssertEqual(InboxScanPollingPolicy.retryDelay(for: 0), .seconds(3))
        XCTAssertEqual(InboxScanPollingPolicy.retryDelay(for: 3), .seconds(9))
        XCTAssertEqual(InboxScanPollingPolicy.retryDelay(for: 99), .seconds(30))
    }
}
