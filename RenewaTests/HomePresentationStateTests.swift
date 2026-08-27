import XCTest
@testable import Renewa

@MainActor
final class HomePresentationStateTests: XCTestCase {
    private let reference = date(2026, 8, 22)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    // MARK: - Totals

    func test_monthPeriod_showsMonthlyTotalAndProjectsTheYear() {
        let state = makeState(
            period: .month,
            inputs: [input(price: 20), input(price: 10, cycle: .yearly)]
        )

        XCTAssertEqual(state.periodLabel, "This month")
        assertText(state.totalText, "$20.83")
        assertText(state.subtitle, "About $250.00 a year at this rate")
    }

    func test_yearPeriod_multipliesTheMonthlyTotalAndCountsSubscriptions() {
        let state = makeState(period: .year, inputs: [input(price: 20), input(price: 5)])

        XCTAssertEqual(state.periodLabel, "This year")
        assertText(state.totalText, "$300.00")
        XCTAssertEqual(state.subtitle, "Across 2 subscriptions at today's prices")
        XCTAssertEqual(state.countLabel, "2 active · by renewal")
    }

    func test_unconvertibleSubscription_isExcludedFromTheTotalButStillListed() {
        let state = makeState(
            inputs: [
                input(price: 20),
                input(name: "Arte", price: 9.90, currency: "EUR", convertible: false),
            ]
        )

        assertText(state.totalText, "$20.00")
        XCTAssertEqual(state.cards.count, 2)
        assertText(state.cards.first { $0.subscription.name == "Arte" }?.periodPriceText, "€9.90")
    }

    func test_noSubscriptions_reportsAnEmptyScreenWithoutSegmentsOrNextCharge() {
        let state = makeState(inputs: [])

        assertText(state.totalText, "$0.00")
        XCTAssertEqual(state.countLabel, "Nothing tracked")
        XCTAssertTrue(state.segments.isEmpty)
        XCTAssertNil(state.nextCharge)
    }

    // MARK: - Delta

    func test_spendIncrease_readsAsAnIncreaseSinceThePreviousMonth() {
        let state = makeState(inputs: [input(price: 20)], previousPeriod: (12, "July"))

        assertText(state.deltaLabel, "+$8.00 since July")
        XCTAssertEqual(state.deltaDirection, .up)
    }

    func test_spendDecrease_usesAMinusSignAndTheCalmerTone() {
        let state = makeState(inputs: [input(price: 20)], previousPeriod: (30, "July"))

        assertText(state.deltaLabel, "−$10.00 since July")
        XCTAssertEqual(state.deltaDirection, .down)
    }

    func test_unchangedSpend_readsAsFlatRatherThanZero() {
        let state = makeState(inputs: [input(price: 20)], previousPeriod: (20, "July"))

        XCTAssertEqual(state.deltaLabel, "same as July")
        XCTAssertEqual(state.deltaDirection, .flat)
    }

    func test_yearPeriod_scalesTheDeltaToAYear() {
        let state = makeState(
            period: .year,
            inputs: [input(price: 20)],
            previousPeriod: (12, "July")
        )

        assertText(state.deltaLabel, "+$96.00 since July")
    }

    func test_missingSnapshot_hidesTheDeltaEntirely() {
        let state = makeState(inputs: [input(price: 20)], previousPeriod: nil)

        XCTAssertNil(state.deltaLabel)
        XCTAssertEqual(state.deltaDirection, .flat)
    }

    // MARK: - Segments

    func test_segments_groupByCategoryAndSortByShare() {
        let state = makeState(
            inputs: [
                input(name: "Netflix", price: 15, category: .entertainment),
                input(name: "Figma", price: 30, category: .work),
                input(name: "Spotify", price: 5, category: .entertainment),
            ]
        )

        XCTAssertEqual(state.segments.map(\.category), [.work, .entertainment])
        XCTAssertEqual(state.segments.map(\.shareLabel), ["60%", "40%"])
        XCTAssertEqual(state.segments.first?.amount, 30)
    }

    func test_segments_skipSubscriptionsWithoutAConvertedCost() {
        let state = makeState(
            inputs: [
                input(price: 20, category: .work),
                input(name: "Arte", price: 9.90, currency: "EUR", category: .entertainment, convertible: false),
            ]
        )

        XCTAssertEqual(state.segments.map(\.category), [.work])
        XCTAssertEqual(state.segments.first?.shareLabel, "100%")
    }

    // MARK: - Cards

    func test_cards_sortByRenewalDateThenName() {
        let state = makeState(
            inputs: [
                input(name: "Figma", renewal: date(2026, 9, 4)),
                input(name: "Netflix", renewal: date(2026, 8, 24)),
                input(name: "Adobe", renewal: date(2026, 9, 4)),
            ]
        )

        XCTAssertEqual(state.cards.map(\.subscription.name), ["Netflix", "Adobe", "Figma"])
    }

    func test_renewalWithinAWeek_isMarkedUrgent() {
        let state = makeState(
            inputs: [
                input(name: "Netflix", renewal: date(2026, 8, 27)),
                input(name: "Figma", renewal: date(2026, 9, 30)),
            ]
        )

        XCTAssertEqual(state.cards.first { $0.subscription.name == "Netflix" }?.isUrgent, true)
        XCTAssertEqual(state.cards.first { $0.subscription.name == "Figma" }?.isUrgent, false)
    }

    func test_renewLabel_readsInDaysNearbyAndAsADateFurtherOut() {
        let state = makeState(
            inputs: [
                input(name: "Today", renewal: date(2026, 8, 22)),
                input(name: "Tomorrow", renewal: date(2026, 8, 23)),
                input(name: "Soon", renewal: date(2026, 8, 27)),
                input(name: "Annual", cycle: .yearly, renewal: date(2027, 3, 3)),
                input(name: "Lapsed", renewal: date(2026, 8, 19)),
            ]
        )

        XCTAssertEqual(label(state, "Today"), "today")
        XCTAssertEqual(label(state, "Tomorrow"), "tomorrow")
        XCTAssertEqual(label(state, "Soon"), "in 5 days")
        XCTAssertEqual(label(state, "Lapsed"), "past due")
        XCTAssertEqual(label(state, "Annual")?.hasPrefix("on "), true)
    }

    func test_cycleProgress_measuresAgainstTheCycleThatIsEnding() {
        let state = makeState(
            inputs: [
                input(name: "Monthly", renewal: date(2026, 9, 6)),
                input(name: "Weekly", cycle: .weekly, renewal: date(2026, 8, 24)),
                input(name: "Lapsed", renewal: date(2026, 8, 19)),
            ]
        )

        // 15 of a 31-day cycle remain.
        XCTAssertEqual(progress(state, "Monthly") ?? 0, 1 - 15.0 / 31.0, accuracy: 0.0001)
        // 2 of a 7-day cycle remain.
        XCTAssertEqual(progress(state, "Weekly") ?? 0, 1 - 2.0 / 7.0, accuracy: 0.0001)
        XCTAssertEqual(progress(state, "Lapsed"), 1)
    }

    func test_convertedSubscription_showsTheDisplayCurrencyWithTheChargedAmountBeneath() {
        let state = makeState(
            inputs: [
                input(name: "Arte", price: 9.90, currency: "EUR", convertedMonthly: 11, convertedPrice: 11)
            ]
        )

        assertText(state.cards.first?.periodPriceText, "$11.00")
        assertText(state.cards.first?.nativePriceText, "€9.90")
        XCTAssertEqual(state.cards.first?.perLabel, "per month")
    }

    // MARK: - Next charge

    func test_nextCharge_picksTheSoonestUpcomingRenewal() {
        let state = makeState(
            inputs: [
                input(name: "Figma", price: 15, renewal: date(2026, 9, 4)),
                input(name: "Netflix", price: 15.49, renewal: date(2026, 8, 24)),
            ]
        )

        XCTAssertEqual(state.nextCharge?.name, "Netflix")
        XCTAssertEqual(state.nextCharge?.daysAway, 2)
        assertText(state.nextCharge?.priceText, "$15.49")
        XCTAssertEqual(state.nextCharge?.isUrgent, true)
        XCTAssertEqual(
            state.nextCharge?.summary,
            "Netflix renews " + date(2026, 8, 24).formatted(.dateTime.month(.abbreviated).day())
        )
    }

    func test_nextCharge_prefersAnUpcomingRenewalOverALapsedOne() {
        let state = makeState(
            inputs: [
                input(name: "Lapsed", renewal: date(2026, 8, 1)),
                input(name: "Upcoming", renewal: date(2026, 8, 30)),
            ]
        )

        XCTAssertEqual(state.nextCharge?.name, "Upcoming")
    }

    func test_nextCharge_wordsTodayAndTomorrowRatherThanADate() {
        let today = makeState(inputs: [input(name: "Netflix", renewal: date(2026, 8, 22))])
        let tomorrow = makeState(inputs: [input(name: "Netflix", renewal: date(2026, 8, 23))])

        XCTAssertEqual(today.nextCharge?.summary, "Netflix renews today")
        XCTAssertEqual(tomorrow.nextCharge?.summary, "Netflix renews tomorrow")
    }

    // MARK: - Greeting

    func test_greeting_followsTheTimeOfDay() {
        XCTAssertEqual(makeState(reference: date(2026, 8, 22, hour: 8)).greeting, "Good morning, Meirzhan")
        XCTAssertEqual(makeState(reference: date(2026, 8, 22, hour: 14)).greeting, "Good afternoon, Meirzhan")
        XCTAssertEqual(makeState(reference: date(2026, 8, 22, hour: 21)).greeting, "Good evening, Meirzhan")
    }

    // MARK: - Segment layout

    func test_segmentWidths_fillTheTrackMinusTheGaps() {
        let widths = SpendSegmentLayout.widths(for: [0.5, 0.3, 0.2], available: 206)
        let gaps = SpendSegmentLayout.gap * 2

        XCTAssertEqual(widths.reduce(0, +) + gaps, 206, accuracy: 0.001)
        XCTAssertEqual(widths[0], 100, accuracy: 0.001)
    }

    func test_segmentWidths_keepATinySliceVisibleWithoutOverflowing() {
        let widths = SpendSegmentLayout.widths(for: [0.99, 0.01], available: 203)

        XCTAssertGreaterThanOrEqual(widths[1], SpendSegmentLayout.minimumWidth * 0.95)
        XCTAssertLessThanOrEqual(widths.reduce(0, +), 200.001)
    }

    // MARK: - Helpers

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

    private func label(_ state: HomePresentationState, _ name: String) -> String? {
        state.cards.first { $0.subscription.name == name }?.renewLabel
    }

    private func progress(_ state: HomePresentationState, _ name: String) -> Double? {
        state.cards.first { $0.subscription.name == name }?.cycleProgress
    }

    private func makeState(
        period: HomePresentationState.Period = .month,
        displayName: String = "Meirzhan",
        inputs: [HomePresentationState.Input] = [],
        previousPeriod: (amount: Decimal, label: String)? = nil,
        conversionNote: String? = nil,
        suggestions: [HomePresentationState.Suggestion] = [],
        reference: Date? = nil
    ) -> HomePresentationState {
        HomePresentationState(
            period: period,
            displayName: displayName,
            inputs: inputs,
            displayCurrency: "USD",
            previousPeriod: previousPeriod,
            conversionNote: conversionNote,
            suggestions: suggestions,
            referenceDate: reference ?? self.reference,
            calendar: calendar
        )
    }

    private func input(
        name: String = "ChatGPT Plus",
        price: Decimal = 20,
        currency: String = "USD",
        cycle: BillingCycle = .monthly,
        category: SubscriptionCategory = .work,
        renewal: Date? = nil,
        convertible: Bool = true,
        convertedMonthly: Decimal? = nil,
        convertedPrice: Decimal? = nil
    ) -> HomePresentationState.Input {
        let subscription = Subscription(
            id: UUID(),
            userID: nil,
            name: name,
            price: price,
            currency: currency,
            billingCycle: cycle,
            nextRenewalDate: renewal ?? date(2026, 9, 6),
            category: category,
            status: .active,
            iconName: String(name.prefix(1)),
            brandID: nil,
            tintHex: "5B8A72",
            source: "manual",
            createdAt: nil,
            updatedAt: nil
        )

        return .init(
            subscription: subscription,
            convertedMonthlyCost: convertible ? (convertedMonthly ?? subscription.monthlyCost) : nil,
            convertedPrice: convertible ? (convertedPrice ?? price) : nil
        )
    }
}

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour)
    ) ?? .distantPast
}
