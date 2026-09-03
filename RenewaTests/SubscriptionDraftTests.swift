import XCTest
@testable import Renewa

/// `SubscriptionDraft` is what makes the agent's review sheet and the manual "New subscription"
/// form the same screen, so these cover the seams: how a discovery fills the form, and what the
/// form sends back.
final class SubscriptionDraftTests: XCTestCase {
    @MainActor
    func test_draftFromCandidate_carriesEveryExtractedField() {
        let renewal = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        let draft = SubscriptionDraft(
            candidate: makeCandidate(
                amount: 22.99,
                currency: "eur",
                billingCycle: .yearly,
                renewalDate: renewal,
                category: .work
            )
        )

        XCTAssertEqual(draft.name, "Netflix")
        XCTAssertEqual(draft.amount, 22.99)
        XCTAssertEqual(draft.normalizedCurrency, "EUR")
        XCTAssertEqual(draft.billingCycle, .yearly)
        XCTAssertEqual(draft.renewalDate, renewal)
        XCTAssertEqual(draft.category, .work)
    }

    @MainActor
    func test_draftFromIncompleteCandidate_fallsBackToTheManualFormDefaults() {
        // An extraction that found a merchant but no money must not open the form on an empty
        // cycle or a nil date — the user should see the same starting point as adding by hand.
        let draft = SubscriptionDraft(
            candidate: makeCandidate(amount: nil, currency: nil, billingCycle: nil, renewalDate: nil)
        )

        XCTAssertEqual(draft.priceText, "")
        XCTAssertNil(draft.amount)
        XCTAssertEqual(draft.normalizedCurrency, "USD")
        XCTAssertEqual(draft.billingCycle, .monthly)
        XCTAssertEqual(
            Calendar.current.dateComponents([.year, .month, .day], from: draft.renewalDate),
            Calendar.current.dateComponents([.year, .month, .day], from: SubscriptionDraft.defaultRenewalDate)
        )
    }

    @MainActor
    func test_priceTypedWithADecimalComma_parsesAsTheSameAmountAsADot() {
        var draft = SubscriptionDraft(currency: "EUR")
        draft.priceText = "9,99"
        XCTAssertEqual(draft.amount, 9.99)

        draft.priceText = "9.99"
        XCTAssertEqual(draft.amount, 9.99)
    }

    @MainActor
    func test_logoResolvesFromTheNameUntilTheUserPicksOne() {
        var draft = SubscriptionDraft(name: "Netflix", currency: "USD")
        XCTAssertEqual(draft.effectiveBrandID, SubscriptionBrand.resolve("Netflix")?.id)

        draft.selectedBrandID = nil
        // A stale `selectedBrandID` must stay inert until the picker actually reports a choice.
        XCTAssertEqual(draft.effectiveBrandID, SubscriptionBrand.resolve("Netflix")?.id)

        draft.hasManuallySelectedBrand = true
        XCTAssertNil(draft.effectiveBrandID, "choosing no logo is a decision, not an absent value")
    }

    @MainActor
    func test_reviewedEditsClaimTheLogoChoice_soANoLogoAnswerIsNotOverwritten() {
        var draft = SubscriptionDraft(name: "Netflix", currency: "USD")
        draft.hasManuallySelectedBrand = true
        draft.selectedBrandID = nil

        let edits = draft.candidateEdits
        XCTAssertNil(edits.brandID)
        XCTAssertTrue(edits.hasLogoChoice, "the review sheet showed the picker, so it owns the answer")
    }

    @MainActor
    func test_oneTapTrackEdits_leaveTheLogoToTheServer() {
        // Tapping "Track it" never shows a picker, so it must not claim an answer — otherwise a
        // card confirmed without opening the sheet would be saved with no logo at all.
        let edits = EmailCandidateEdits(candidate: makeCandidate())

        XCTAssertNil(edits.brandID)
        XCTAssertFalse(edits.hasLogoChoice)
    }

    @MainActor
    func test_draftBuildsTheSameSubscriptionShapeTheManualFormSaves() {
        var draft = SubscriptionDraft(name: "  Notion  ", currency: "usd")
        draft.priceText = "10"
        draft.category = .work

        let subscription = draft.subscription(source: "manual")

        XCTAssertEqual(subscription.name, "Notion")
        XCTAssertEqual(subscription.price, 10)
        XCTAssertEqual(subscription.currency, "USD")
        XCTAssertEqual(subscription.iconName, "N")
        XCTAssertEqual(subscription.tintHex, SubscriptionCategory.work.defaultTint)
        XCTAssertEqual(subscription.source, "manual")
    }

    private func makeCandidate(
        amount: Decimal? = 22.99,
        currency: String? = "USD",
        billingCycle: BillingCycle? = .monthly,
        renewalDate: Date? = .now,
        category: SubscriptionCategory = .entertainment,
        eventType: String = "created"
    ) -> EmailSubscriptionCandidate {
        EmailSubscriptionCandidate(
            id: UUID(),
            matchedSubscriptionID: nil,
            suggestedAction: .add,
            reviewStatus: .pending,
            merchantName: "Netflix",
            amount: amount,
            currency: currency,
            billingCycle: billingCycle,
            renewalDate: renewalDate,
            category: category,
            eventType: eventType,
            confidence: 0.92,
            evidence: "A monthly subscription event was detected.",
            validationIssues: [],
            resolutionReason: nil,
            evidenceEvents: nil,
            createdAt: .now
        )
    }
}
