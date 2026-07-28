import Foundation

struct SubscriptionDeadline: Identifiable, Hashable {
    let subscription: Subscription
    let date: Date

    var id: String {
        "\(subscription.id.uuidString)-\(date.timeIntervalSinceReferenceDate)"
    }
}

struct SubscriptionDeadlineProjector {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func deadlines(
        for subscriptions: [Subscription],
        inMonthContaining month: Date
    ) -> [SubscriptionDeadline] {
        let monthStart = startOfMonth(containing: month)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        return deadlines(for: subscriptions, from: monthStart, until: monthEnd)
    }

    func deadlines(
        for subscriptions: [Subscription],
        from start: Date,
        until end: Date
    ) -> [SubscriptionDeadline] {
        let rangeStart = calendar.startOfDay(for: start)
        let rangeEnd = calendar.startOfDay(for: end)

        guard rangeStart < rangeEnd else { return [] }

        return subscriptions
            .filter { $0.status == .active }
            .flatMap { subscription in
                deadlines(for: subscription, from: rangeStart, until: rangeEnd)
            }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    return lhs.subscription.name.localizedCaseInsensitiveCompare(rhs.subscription.name) == .orderedAscending
                }
                return lhs.date < rhs.date
            }
    }

    func groupedDeadlines(
        for subscriptions: [Subscription],
        from start: Date,
        until end: Date
    ) -> [Date: [SubscriptionDeadline]] {
        Dictionary(grouping: deadlines(for: subscriptions, from: start, until: end)) { deadline in
            calendar.startOfDay(for: deadline.date)
        }
    }

    private func deadlines(
        for subscription: Subscription,
        from start: Date,
        until end: Date
    ) -> [SubscriptionDeadline] {
        let anchor = calendar.startOfDay(for: subscription.nextRenewalDate)
        var occurrenceIndex = firstOccurrenceIndex(
            for: subscription.billingCycle,
            anchor: anchor,
            onOrAfter: start
        )
        var results: [SubscriptionDeadline] = []

        while let date = occurrence(
            for: subscription.billingCycle,
            anchor: anchor,
            index: occurrenceIndex
        ), date < end {
            if date >= start {
                results.append(SubscriptionDeadline(subscription: subscription, date: date))
            }
            occurrenceIndex += 1
        }

        return results
    }

    private func firstOccurrenceIndex(
        for cycle: BillingCycle,
        anchor: Date,
        onOrAfter start: Date
    ) -> Int {
        switch cycle {
        case .weekly:
            let days = calendar.dateComponents([.day], from: anchor, to: start).day ?? 0
            return days > 0 ? (days + 6) / 7 : 0
        case .monthly, .quarterly, .yearly:
            let step = monthStep(for: cycle)
            let months = calendar.dateComponents([.month], from: anchor, to: start).month ?? 0
            return max(0, months / step)
        }
    }

    private func occurrence(
        for cycle: BillingCycle,
        anchor: Date,
        index: Int
    ) -> Date? {
        switch cycle {
        case .weekly:
            return calendar.date(byAdding: .day, value: index * 7, to: anchor)
        case .monthly, .quarterly, .yearly:
            let step = monthStep(for: cycle)
            return calendar.date(byAdding: .month, value: index * step, to: anchor)
        }
    }

    private func monthStep(for cycle: BillingCycle) -> Int {
        switch cycle {
        case .monthly: 1
        case .quarterly: 3
        case .yearly: 12
        case .weekly: 0
        }
    }

    private func startOfMonth(containing date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.calendar, .year, .month], from: date))
            ?? calendar.startOfDay(for: date)
    }
}
