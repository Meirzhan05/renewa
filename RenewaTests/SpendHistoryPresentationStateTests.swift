import XCTest

@testable import Renewa

@MainActor
final class SpendHistoryPresentationStateTests: XCTestCase {
    // 2026-08-25, the month the six-month fixture below ends on.
    private let reference = date(2026, 8, 25)

    // MARK: - Window

    func test_moreMonthsThanFit_keepsTheMostRecentSix() {
        let state = makeState(
            inputs: (1...9).map { month in
                input(date(2026, month, 1), total: Decimal(month))
            }
        )

        XCTAssertEqual(state.months.count, SpendHistoryPresentationState.windowLength)
        XCTAssertEqual(state.months.map(\.shortLabel), ["Apr", "May", "Jun", "Jul", "Aug", "Sep"])
        XCTAssertEqual(state.windowLabel, "Last 6 months")
    }

    func test_unorderedInputs_arePlottedOldestFirst() {
        let state = makeState(
            inputs: [
                input(date(2026, 8, 1), total: 30),
                input(date(2026, 6, 1), total: 10),
                input(date(2026, 7, 1), total: 20),
            ]
        )

        XCTAssertEqual(state.months.map(\.shortLabel), ["Jun", "Jul", "Aug"])
    }

    func test_singleMonth_readsAsThisMonthAndDrawsNoLine() {
        let state = makeState(inputs: [input(date(2026, 8, 1), total: 30)])

        XCTAssertEqual(state.windowLabel, "This month")
        XCTAssertFalse(state.hasTrendLine)
        XCTAssertFalse(state.isEmpty)
    }

    func test_noHistory_leavesEveryFigureBlankRatherThanZeroed() {
        let state = makeState(inputs: [])

        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(state.windowLabel, "No history yet")
        XCTAssertNil(state.selectedMonth)
        XCTAssertTrue(state.categories.isEmpty)
        XCTAssertEqual(state.deltaLabel, "")
    }

    // MARK: - Selection

    func test_noSelection_landsOnTheLatestMonth() {
        let state = makeState(inputs: sixMonths)

        XCTAssertEqual(state.selectedIndex, 5)
        XCTAssertEqual(state.selectedTitle, "August")
        assertText(state.selectedTotalText, "$75.47")
    }

    func test_selectionBeyondTheWindow_clampsRatherThanCrashing() {
        let state = makeState(inputs: sixMonths, selectedIndex: 40)

        XCTAssertEqual(state.selectedIndex, 5)
        XCTAssertEqual(state.selectedTitle, "August")
    }

    func test_monthInAnotherYear_carriesTheYear() {
        let state = makeState(
            inputs: [input(date(2025, 11, 1), total: 10), input(date(2025, 12, 1), total: 12)]
        )

        XCTAssertEqual(state.selectedTitle, "December 2025")
    }

    // MARK: - Delta

    func test_spendUp_readsAsAnIncreaseFromThePreviousMonth() {
        let state = makeState(inputs: sixMonths, selectedIndex: 5)

        assertText(state.deltaLabel, "+$8.00 from Jul")
        XCTAssertEqual(state.deltaDirection, .up)
    }

    func test_spendDown_usesATypographicMinus() {
        let state = makeState(
            inputs: [input(date(2026, 7, 1), total: 50), input(date(2026, 8, 1), total: 40)]
        )

        assertText(state.deltaLabel, "−$10.00 from Jul")
        XCTAssertEqual(state.deltaDirection, .down)
    }

    func test_unchangedSpend_saysSoRatherThanShowingZero() {
        let state = makeState(
            inputs: [input(date(2026, 7, 1), total: 50), input(date(2026, 8, 1), total: 50)]
        )

        XCTAssertEqual(state.deltaLabel, "same as Jul")
        XCTAssertEqual(state.deltaDirection, .flat)
    }

    func test_firstMonthOnRecord_hasNothingToCompareAgainst() {
        let state = makeState(inputs: sixMonths, selectedIndex: 0)

        XCTAssertEqual(state.deltaLabel, "first month recorded")
        XCTAssertEqual(state.deltaDirection, .unknown)
    }

    // MARK: - Plotted points

    func test_points_spanTheFullWidthWithTheLowMonthOnTheFloor() {
        let state = makeState(
            inputs: [
                input(date(2026, 6, 1), total: 10),
                input(date(2026, 7, 1), total: 20),
                input(date(2026, 8, 1), total: 30),
            ]
        )

        XCTAssertEqual(state.months.map(\.x), [0, 0.5, 1])
        XCTAssertEqual(state.months.map(\.y), [0, 0.5, 1])
    }

    func test_flatSeries_sitsOnTheMidLineRatherThanCollapsing() {
        let state = makeState(
            inputs: [input(date(2026, 7, 1), total: 20), input(date(2026, 8, 1), total: 20)]
        )

        XCTAssertEqual(state.months.map(\.y), [0.5, 0.5])
    }

    func test_index_forDragPosition_snapsToTheNearestMonth() {
        XCTAssertEqual(SpendHistoryPresentationState.index(forXFraction: -0.4, count: 6), 0)
        XCTAssertEqual(SpendHistoryPresentationState.index(forXFraction: 0.0, count: 6), 0)
        XCTAssertEqual(SpendHistoryPresentationState.index(forXFraction: 0.44, count: 6), 2)
        XCTAssertEqual(SpendHistoryPresentationState.index(forXFraction: 1.0, count: 6), 5)
        XCTAssertEqual(SpendHistoryPresentationState.index(forXFraction: 3.2, count: 6), 5)
        XCTAssertEqual(SpendHistoryPresentationState.index(forXFraction: 0.7, count: 1), 0)
    }

    // MARK: - Categories

    func test_categories_areRankedWithTheLargestFillingItsTrack() {
        let state = makeState(inputs: sixMonths)

        XCTAssertEqual(
            state.categories.map(\.category),
            [.work, .entertainment, .health, .cloud, .learning]
        )
        XCTAssertEqual(state.categories.first?.barFraction, 1)
        assertText(state.categories.first?.amountText, "$32.00")
        XCTAssertEqual(state.categories.first?.shareLabel, "42%")
    }

    func test_categoriesWithNoSpend_areLeftOut() {
        let state = makeState(
            inputs: [
                input(date(2026, 8, 1), total: 10, categories: [.work: 10, .cloud: 0])
            ]
        )

        XCTAssertEqual(state.categories.map(\.category), [.work])
    }

    func test_categoryChange_comparesAgainstTheSameCategoryAMonthEarlier() {
        let state = makeState(inputs: sixMonths, selectedIndex: 5)
        let work = state.categories.first { $0.category == .work }

        assertText(work?.changeLabel, "+$8.00 from Jul")
        XCTAssertEqual(work?.changeDirection, .up)
    }

    func test_categoryAbsentLastMonth_readsAsNewRatherThanAsAnIncrease() {
        let state = makeState(inputs: sixMonths, selectedIndex: 4)
        let health = state.categories.first { $0.category == .health }

        XCTAssertEqual(health?.changeLabel, "new since Jun")
        XCTAssertEqual(health?.changeDirection, .up)
    }

    func test_steadyCategory_saysUnchanged() {
        let state = makeState(inputs: sixMonths, selectedIndex: 5)
        let entertainment = state.categories.first { $0.category == .entertainment }

        XCTAssertEqual(entertainment?.changeLabel, "unchanged from Jul")
        XCTAssertEqual(entertainment?.changeDirection, .flat)
    }

    func test_firstMonthOnRecord_hasNoCategoryComparison() {
        let state = makeState(inputs: sixMonths, selectedIndex: 0)

        XCTAssertTrue(state.categories.allSatisfy { $0.changeLabel == nil })
        XCTAssertTrue(state.categories.allSatisfy { !$0.isExpandable })
    }

    // MARK: - Line items

    func test_currentMonth_listsWhatIsTrackedInTheCategory() {
        let state = makeState(
            inputs: sixMonths,
            currentLineItems: [.work: [lineItem("ChatGPT Plus"), lineItem("Figma")]]
        )
        let work = state.categories.first { $0.category == .work }

        XCTAssertEqual(work?.items.map(\.name), ["ChatGPT Plus", "Figma"])
        XCTAssertEqual(work?.isExpandable, true)
    }

    func test_closedMonth_keepsItsTotalsWithoutBorrowingTodaysLineItems() {
        let state = makeState(
            inputs: sixMonths,
            selectedIndex: 3,
            currentLineItems: [.work: [lineItem("ChatGPT Plus"), lineItem("Figma")]]
        )
        let work = state.categories.first { $0.category == .work }

        XCTAssertEqual(work?.items, [])
        // Still openable — the month-over-month change is worth reading on its own.
        XCTAssertEqual(work?.isExpandable, true)
    }

    // MARK: - Helpers

    /// March through August 2026: work doubles then grows, health appears in July, entertainment holds.
    private var sixMonths: [SpendHistoryPresentationState.Input] {
        [
            input(date(2026, 3, 1), total: 33.48, categories: [.entertainment: 15.49, .work: 12, .cloud: 5.99]),
            input(date(2026, 4, 1), total: 37.48, categories: [.entertainment: 15.49, .work: 12, .cloud: 9.99]),
            input(
                date(2026, 5, 1),
                total: 42.48,
                categories: [.entertainment: 15.49, .work: 12, .cloud: 9.99, .learning: 5]
            ),
            input(
                date(2026, 6, 1),
                total: 54.48,
                categories: [.entertainment: 15.49, .work: 24, .cloud: 9.99, .learning: 5]
            ),
            input(
                date(2026, 7, 1),
                total: 67.47,
                categories: [.entertainment: 15.49, .work: 24, .cloud: 9.99, .learning: 5, .health: 12.99]
            ),
            input(
                date(2026, 8, 1),
                total: 75.47,
                categories: [.entertainment: 15.49, .work: 32, .cloud: 9.99, .learning: 5, .health: 12.99]
            ),
        ]
    }

    private func makeState(
        inputs: [SpendHistoryPresentationState.Input],
        selectedIndex: Int? = nil,
        currentLineItems: [SubscriptionCategory: [SpendHistoryPresentationState.LineItem]] = [:]
    ) -> SpendHistoryPresentationState {
        SpendHistoryPresentationState(
            inputs: inputs,
            selectedIndex: selectedIndex,
            displayCurrency: "USD",
            currentLineItems: currentLineItems,
            referenceDate: reference,
            calendar: utcCalendar
        )
    }

    private func input(
        _ periodStart: Date,
        total: Decimal,
        categories: [SubscriptionCategory: Decimal] = [:]
    ) -> SpendHistoryPresentationState.Input {
        SpendHistoryPresentationState.Input(
            periodStart: periodStart,
            total: total,
            categoryTotals: categories
        )
    }

    private func lineItem(_ name: String) -> SpendHistoryPresentationState.LineItem {
        SpendHistoryPresentationState.LineItem(id: UUID(), name: name, priceText: "$1.00")
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
}

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utcCalendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
}
