import XCTest
@testable import Renewa

@MainActor
final class InsightsSummaryPresentationStateTests: XCTestCase {
    func test_aiReport_exposesFreshAIProvenance() {
        let state = InsightsSummaryPresentationState(report: makeReport(source: .ai, isCached: false))

        XCTAssertEqual(state.title, "Renewa’s read")
        XCTAssertEqual(state.sourceLabel, "AI-generated")
        XCTAssertFalse(state.isAIDegraded)
        XCTAssertEqual(state.evidenceLabel, "Based on 2 active subscriptions, 3 billing events, and 1 monthly snapshot")
    }

    func test_cachedAIReport_exposesCachedAIProvenance() {
        let state = InsightsSummaryPresentationState(report: makeReport(source: .ai, isCached: true))

        XCTAssertEqual(state.sourceLabel, "AI-generated · Cached")
        XCTAssertFalse(state.isAIDegraded)
    }

    func test_deterministicReport_neverClaimsToBeAI() {
        let state = InsightsSummaryPresentationState(report: makeReport(source: .deterministic))

        XCTAssertEqual(state.title, "Basic subscription summary")
        XCTAssertEqual(state.sourceLabel, "Basic subscription summary")
        XCTAssertTrue(state.isAIDegraded)
    }

    func test_zeroEvidence_omitsPrivacySafeEvidenceLine() {
        let state = InsightsSummaryPresentationState(
            report: makeReport(
                source: .ai,
                evidence: InsightEvidenceSummary(
                    activeSubscriptionCount: 0,
                    billingEventCount: 0,
                    monthlySnapshotCount: 0
                )
            )
        )

        XCTAssertNil(state.evidenceLabel)
    }

    func test_legacyReport_usesExistingSourceFlagWithoutAssumingCache() {
        let report = InsightReport(
            summary: "A legacy insight",
            cards: [],
            generatedAt: Date(timeIntervalSince1970: 0),
            isAIGenerated: true,
            provenance: nil
        )

        let state = InsightsSummaryPresentationState(report: report)

        XCTAssertEqual(state.sourceLabel, "AI-generated")
        XCTAssertNil(state.evidenceLabel)
    }

    private func makeReport(
        source: InsightSummarySource,
        isCached: Bool = false,
        evidence: InsightEvidenceSummary = InsightEvidenceSummary(
            activeSubscriptionCount: 2,
            billingEventCount: 3,
            monthlySnapshotCount: 1
        )
    ) -> InsightReport {
        InsightReport(
            summary: "Your commitments are steady.",
            cards: [],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isAIGenerated: source == .ai,
            provenance: InsightProvenance(
                source: source,
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isCached: isCached,
                evidence: evidence
            )
        )
    }
}
