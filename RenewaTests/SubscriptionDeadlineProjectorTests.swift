import XCTest
@testable import Renewa

final class SubscriptionDeadlineProjectorTests: XCTestCase {
    @MainActor
    func test_monthlyProjection_preservesAnchorAfterShortenedMonth() {
        let calendar = utcCalendar
        let projector = SubscriptionDeadlineProjector(calendar: calendar)
        let subscription = makeSubscription(cycle: .monthly, renewal: date(2026, 1, 31))

        let deadlines = projector.deadlines(
            for: [subscription],
            from: date(2026, 2, 1),
            until: date(2026, 4, 1)
        )

        XCTAssertEqual(deadlines.map(\.date), [date(2026, 2, 28), date(2026, 3, 31)])
    }

    @MainActor
    func test_projection_includesWeeklyQuarterlyAndYearlyOccurrences() {
        let calendar = utcCalendar
        let projector = SubscriptionDeadlineProjector(calendar: calendar)
        let subscriptions = [
            makeSubscription(name: "Weekly", cycle: .weekly, renewal: date(2026, 7, 1)),
            makeSubscription(name: "Quarterly", cycle: .quarterly, renewal: date(2026, 1, 15)),
            makeSubscription(name: "Yearly", cycle: .yearly, renewal: date(2025, 7, 9))
        ]

        let deadlines = projector.deadlines(
            for: subscriptions,
            from: date(2026, 7, 1),
            until: date(2026, 8, 1)
        )

        XCTAssertEqual(
            deadlines.map { "\(calendar.component(.day, from: $0.date))-\($0.subscription.name)" },
            ["1-Weekly", "8-Weekly", "9-Yearly", "15-Quarterly", "15-Weekly", "22-Weekly", "29-Weekly"]
        )
    }

    @MainActor
    func test_groupedDeadlines_groupsPaymentsByCalendarDay() {
        let projector = SubscriptionDeadlineProjector(calendar: utcCalendar)
        let subscriptions = [
            makeSubscription(name: "One", renewal: date(2026, 8, 12)),
            makeSubscription(name: "Two", renewal: date(2026, 8, 12))
        ]

        let grouped = projector.groupedDeadlines(
            for: subscriptions,
            from: date(2026, 8, 1),
            until: date(2026, 9, 1)
        )

        XCTAssertEqual(grouped[date(2026, 8, 12)]?.map(\.subscription.name), ["One", "Two"])
    }

    @MainActor
    func test_projection_excludesCanceledAndPausedSubscriptions() {
        let projector = SubscriptionDeadlineProjector(calendar: utcCalendar)
        let active = makeSubscription(name: "Active", renewal: date(2026, 8, 12))
        var canceled = makeSubscription(name: "Canceled", renewal: date(2026, 8, 12))
        var paused = makeSubscription(name: "Paused", renewal: date(2026, 8, 12))
        canceled.status = .canceled
        paused.status = .paused

        let deadlines = projector.deadlines(
            for: [active, canceled, paused],
            from: date(2026, 8, 1),
            until: date(2026, 9, 1)
        )

        XCTAssertEqual(deadlines.map(\.subscription.name), ["Active"])
    }

    @MainActor
    private func makeSubscription(
        name: String = "Subscription",
        cycle: BillingCycle = .monthly,
        renewal: Date,
        status: SubscriptionStatus = .active
    ) -> Subscription {
        Subscription(
            id: UUID(),
            userID: nil,
            name: name,
            price: 10,
            currency: "USD",
            billingCycle: cycle,
            nextRenewalDate: renewal,
            category: .other,
            status: status,
            iconName: "S",
            brandID: nil,
            tintHex: "#000000",
            source: "test",
            createdAt: nil,
            updatedAt: nil
        )
    }

    @MainActor
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @MainActor
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
