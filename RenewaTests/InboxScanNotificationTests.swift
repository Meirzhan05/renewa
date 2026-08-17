import XCTest
@testable import Renewa

@MainActor
final class InboxScanNotificationTests: XCTestCase {
    func test_notificationRoute_acceptsOnlyInboxIntelligencePayloads() {
        let payload: [AnyHashable: Any] = [
                "renewa_route": "inbox-intelligence",
                "renewa_batch_id": "BATCH-123",
            ]
        XCTAssertTrue(InboxNotificationRoute.opensInboxIntelligence(payload))
        XCTAssertEqual(InboxNotificationRoute.batchID(from: payload), "BATCH-123")
        XCTAssertFalse(InboxNotificationRoute.opensInboxIntelligence(["renewa_route": "profile"]))
    }

    func test_liveActivityContentState_preservesCountsWithoutInventingAPercentage() {
        let state = InboxScanLiveActivityAttributes.ContentState(
            stage: "extracting",
            scanned: 42,
            connectionCount: 2,
            outcome: nil,
            discoveryCount: 0,
            route: "inbox-intelligence",
            batchID: "BATCH-123"
        )

        XCTAssertEqual(state.scanned, 42)
        XCTAssertEqual(state.connectionCount, 2)
        XCTAssertNil(state.outcome)
        XCTAssertEqual(state.route, "inbox-intelligence")
    }
}
