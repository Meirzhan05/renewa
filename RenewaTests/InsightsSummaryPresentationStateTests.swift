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

    // MARK: - Prose

    func test_oneBlockSummary_opensWithASerifLeadAndCarriesTheRestBelow() {
        let state = makeState(
            summary: "You will pay $93.95 across eight renewals in the next 30 days. Monthly spend is up since March."
        )

        XCTAssertEqual(state.paragraphs.count, 2)
        XCTAssertTrue(state.paragraphs[0].isLead)
        XCTAssertEqual(
            state.paragraphs[0].plainText,
            "You will pay $93.95 across eight renewals in the next 30 days."
        )
        XCTAssertFalse(state.paragraphs[1].isLead)
        XCTAssertEqual(state.paragraphs[1].plainText, "Monthly spend is up since March.")
    }

    func test_shortTail_staysWithTheLeadRatherThanBecomingAFragment() {
        let state = makeState(summary: "Spending is steady. Nothing new.")

        XCTAssertEqual(state.paragraphs.count, 1)
        XCTAssertEqual(state.paragraphs[0].plainText, "Spending is steady. Nothing new.")
    }

    func test_blankSummary_producesNoParagraphs() {
        XCTAssertTrue(makeState(summary: "   \n  ").paragraphs.isEmpty)
    }

    func test_amounts_areSplitOutSoTheyCanBeSetInTheSerifFace() {
        let state = makeState(summary: "Netflix moves to $17.99 on September 12, adding $48.00 this year.")
        let runs = state.paragraphs[0].runs

        XCTAssertEqual(runs.filter(\.isFigure).map(\.text), ["$17.99", "$48.00"])
        XCTAssertEqual(runs.map(\.text).joined(), "Netflix moves to $17.99 on September 12, adding $48.00 this year.")
    }

    func test_sentenceEndingAmount_doesNotSwallowTheFullStop() {
        let state = makeState(summary: "Dropping one returns $9.99. That is the whole saving on offer.")

        XCTAssertEqual(state.paragraphs[0].runs.filter(\.isFigure).map(\.text), ["$9.99"])
    }

    func test_currencySymbolWithoutANumber_staysPlainProse() {
        let state = makeState(summary: "The $ symbol alone is not a figure worth setting apart.")

        XCTAssertTrue(state.paragraphs[0].runs.allSatisfy { !$0.isFigure })
    }

    func test_amountFusedToText_staysOneWordWhenTheLineWraps() {
        let state = makeState(summary: "Dropping one returns $9.99/mo across the two plans you keep.")
        let words = state.paragraphs[0].words

        let fused = words.first { $0.fragments.contains { $0.text == "$9.99" } }
        XCTAssertEqual(fused?.fragments.map(\.text), ["$9.99", "/mo"])
        XCTAssertEqual(words.map { $0.fragments.map(\.text).joined() }.joined(separator: " "), state.paragraphs[0].plainText)
    }

    // MARK: - Findings

    func test_cards_becomeFindingsPreviewedByTheirFirstSentence() {
        let state = makeState(
            cards: [
                card(
                    title: "Work is your largest category",
                    body: "It has grown from $12.00 to $32.00 since March. Two plans renew in the same week."
                )
            ]
        )

        XCTAssertEqual(state.findings.count, 1)
        XCTAssertEqual(state.findings[0].title, "Work is your largest category")
        XCTAssertEqual(state.findings[0].meta, "It has grown from $12.00 to $32.00 since March.")
        XCTAssertEqual(state.findingsLabel, "1 to review")
    }

    func test_referencedSubscriptions_becomeDetailRowsWithACombinedTotal() {
        let chatGPT = UUID()
        let figma = UUID()
        let state = makeState(
            cards: [card(subscriptionIDs: [chatGPT.uuidString, figma.uuidString])],
            subscriptions: [
                facts(id: chatGPT, name: "ChatGPT Plus", monthlyCost: 20),
                facts(id: figma, name: "Figma", monthlyCost: 12),
            ]
        )

        XCTAssertEqual(
            state.findings[0].rows.map(\.label),
            ["ChatGPT Plus · monthly", "Figma · monthly", "Together, every month"]
        )
        assertText(state.findings[0].rows.last?.valueText, "$32.00")
        XCTAssertEqual(state.findings[0].rows.last?.isEmphasis, true)
    }

    func test_unconvertibleSubscription_showsADashAndIsLeftOutOfTheTotal() {
        let known = UUID()
        let unknown = UUID()
        let state = makeState(
            cards: [card(subscriptionIDs: [known.uuidString, unknown.uuidString])],
            subscriptions: [
                facts(id: known, name: "Figma", monthlyCost: 12),
                facts(id: unknown, name: "Yandex Plus", monthlyCost: nil),
            ]
        )

        XCTAssertEqual(state.findings[0].rows.map(\.valueText).dropFirst().first, "—")
        // One resolvable cost is not a total worth quoting.
        XCTAssertEqual(state.findings[0].rows.count, 2)
    }

    func test_subscriptionsTheCardNamesButRenewaNoLongerTracks_areDropped() {
        let state = makeState(
            cards: [card(subscriptionIDs: [UUID().uuidString, "not-a-uuid"])],
            subscriptions: [facts(id: UUID(), name: "Figma", monthlyCost: 12)]
        )

        XCTAssertTrue(state.findings[0].rows.isEmpty)
    }

    func test_noCards_leavesTheWorthALookHeadingWithNothingToCount() {
        XCTAssertNil(makeState().findingsLabel)
    }

    // MARK: - Helpers

    private func makeState(
        summary: String = "Your commitments are steady.",
        cards: [InsightCard] = [],
        subscriptions: [InsightsSummaryPresentationState.SubscriptionFacts] = []
    ) -> InsightsSummaryPresentationState {
        InsightsSummaryPresentationState(
            report: InsightReport(
                summary: summary,
                cards: cards,
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isAIGenerated: true,
                provenance: nil
            ),
            subscriptions: subscriptions,
            displayCurrency: "USD"
        )
    }

    private func card(
        title: String = "A card",
        body: String = "Some detail about it.",
        subscriptionIDs: [String] = []
    ) -> InsightCard {
        InsightCard(title: title, body: body, subscriptionIDs: subscriptionIDs, eventIDs: [])
    }

    private func facts(
        id: UUID,
        name: String,
        monthlyCost: Decimal?
    ) -> InsightsSummaryPresentationState.SubscriptionFacts {
        InsightsSummaryPresentationState.SubscriptionFacts(
            id: id,
            name: name,
            cadenceLabel: "monthly",
            monthlyCost: monthlyCost
        )
    }

    /// Currency strings carry a non-breaking space between symbol and amount, so compare on the glyphs alone.
    private func assertText(
        _ actual: String?,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual?.filter { !$0.isWhitespace },
            expected.filter { !$0.isWhitespace },
            "expected \"\(expected)\", got \"\(actual ?? "nil")\"",
            file: file,
            line: line
        )
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
