import XCTest
@testable import Renewa

final class InsightsPresentationStateTests: XCTestCase {
    @MainActor
    func test_unresolvedEvidence_waitsForInitialDataLoadOnly() {
        let beforeLoad = makeState(hasLoadedInsightsData: false)
        let reportLoading = makeState(isLoadingInsightReport: true, subscriptionCount: 1)

        XCTAssertEqual(beforeLoad.evidence, .unresolved)
        XCTAssertEqual(reportLoading.evidence, .dashboard)
    }

    @MainActor
    func test_noActiveSubscriptions_withoutInsightEvidenceUsesActivationRatherThanAIDegradedState() {
        let state = makeState()

        XCTAssertEqual(state.evidence, .activation)
    }

    @MainActor
    func test_failureEvidence_doesNotPresentActivationWhenLoadFailed() {
        let state = makeState(hasInsightsError: true)

        XCTAssertEqual(state.evidence, .failure)
    }

    @MainActor
    func test_dashboardEvidence_preservesInactiveSubscriptionHistory() {
        let state = makeState(subscriptionCount: 1)

        XCTAssertEqual(state.evidence, .dashboard)
        XCTAssertEqual(state.commitment, .noActiveSubscriptions)
    }

    @MainActor
    func test_commitmentState_reportsCompletePartialAndUnavailableConversion() {
        let complete = makeState(
            subscriptionCount: 3,
            activeSubscriptionCount: 3
        )
        let partial = makeState(
            subscriptionCount: 3,
            activeSubscriptionCount: 3,
            unavailableConversionCount: 1
        )
        let unavailable = makeState(
            subscriptionCount: 3,
            activeSubscriptionCount: 3,
            unavailableConversionCount: 3
        )

        XCTAssertEqual(complete.commitment, .complete)
        XCTAssertEqual(partial.commitment, .partial(excludedCount: 1))
        XCTAssertEqual(unavailable.commitment, .unavailable(excludedCount: 3))
    }

    @MainActor
    func test_trendState_buildsUntilTwoUsablePointsExist() {
        let empty = makeState()
        let oneMonth = makeState(snapshotCount: 1, usableTrendPointCount: 1)
        let available = makeState(snapshotCount: 2, usableTrendPointCount: 2)

        XCTAssertEqual(empty.trend, .building(periodCount: 0))
        XCTAssertEqual(oneMonth.trend, .building(periodCount: 1))
        XCTAssertEqual(available.trend, .available)
    }

    @MainActor
    func test_trendState_identifiesUnavailableConversion() {
        let state = makeState(snapshotCount: 3, usableTrendPointCount: 1)

        XCTAssertEqual(state.trend, .conversionUnavailable(periodCount: 3))
    }

    @MainActor
    private func makeState(
        hasLoadedInsightsData: Bool = true,
        isLoadingInsightReport: Bool = false,
        subscriptionCount: Int = 0,
        snapshotCount: Int = 0,
        hasInsightReport: Bool = false,
        hasInsightsError: Bool = false,
        activeSubscriptionCount: Int = 0,
        unavailableConversionCount: Int = 0,
        usableTrendPointCount: Int = 0
    ) -> InsightsPresentationState {
        InsightsPresentationState(
            hasLoadedInsightsData: hasLoadedInsightsData,
            isLoadingInsightReport: isLoadingInsightReport,
            subscriptionCount: subscriptionCount,
            snapshotPeriodCount: snapshotCount,
            hasInsightReport: hasInsightReport,
            hasInsightsError: hasInsightsError,
            activeSubscriptionCount: activeSubscriptionCount,
            unavailableConversionCount: unavailableConversionCount,
            usableTrendPointCount: usableTrendPointCount
        )
    }
}
