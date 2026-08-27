import Foundation

/// Everything the Home screen renders, derived once from the store so the view stays declarative
/// and the arithmetic stays testable.
struct HomePresentationState: Equatable {
    enum Period: String, CaseIterable, Identifiable, Equatable {
        case month
        case year

        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: "Month"
            case .year: "Year"
            }
        }
    }

    enum SpendDirection: Equatable {
        case up
        case down
        case flat
    }

    /// One subscription plus whatever the currency layer could resolve for it.
    struct Input: Equatable {
        let subscription: Subscription
        /// Monthly cost expressed in the display currency, or `nil` when no rate was available.
        let convertedMonthlyCost: Decimal?
        /// Charged price expressed in the display currency, or `nil` when no rate was available.
        let convertedPrice: Decimal?

        init(
            subscription: Subscription,
            convertedMonthlyCost: Decimal?,
            convertedPrice: Decimal?
        ) {
            self.subscription = subscription
            self.convertedMonthlyCost = convertedMonthlyCost
            self.convertedPrice = convertedPrice
        }
    }

    struct Segment: Equatable, Identifiable {
        let category: SubscriptionCategory
        let amount: Decimal
        /// Share of the period total, 0...1.
        let fraction: Double

        var id: SubscriptionCategory { category }

        var shareLabel: String { "\(Int((fraction * 100).rounded()))%" }
    }

    struct NextCharge: Equatable {
        let subscriptionID: UUID
        let name: String
        let daysAway: Int
        let dateLabel: String
        let priceText: String

        var isUrgent: Bool { daysAway <= 7 }

        var summary: String {
            switch daysAway {
            case ..<0: "\(name) renewal is past due"
            case 0: "\(name) renews today"
            case 1: "\(name) renews tomorrow"
            default: "\(name) renews \(dateLabel)"
            }
        }
    }

    struct Card: Equatable, Identifiable {
        let subscription: Subscription
        let categoryLabel: String
        let cadenceLabel: String
        /// Cost for the selected period, in the display currency where one could be resolved.
        let periodPriceText: String
        /// Charged amount in its own currency, present only when it differs from the display currency.
        let nativePriceText: String?
        let perLabel: String
        let daysLeft: Int
        let renewLabel: String
        /// How far through the current billing cycle this subscription is, 0...1.
        let cycleProgress: Double

        var id: UUID { subscription.id }

        var isUrgent: Bool { daysLeft <= 7 }

        var accessibilityLabel: String {
            var parts = [subscription.name, "\(categoryLabel), \(cadenceLabel)", "\(periodPriceText) \(perLabel)"]
            if let nativePriceText {
                parts.append("charged \(nativePriceText)")
            }
            parts.append("renews \(renewLabel)")
            return parts.joined(separator: ", ")
        }
    }

    struct Suggestion: Equatable, Identifiable {
        let id: String
        let name: String
    }

    let period: Period
    let greeting: String
    let monthTitle: String
    let periodLabel: String
    let totalText: String
    let subtitle: String
    let conversionNote: String?
    let deltaLabel: String?
    let deltaDirection: SpendDirection
    let segments: [Segment]
    let nextCharge: NextCharge?
    let countLabel: String
    let cards: [Card]
    let suggestions: [Suggestion]

    /// Below this many tracked subscriptions the screen still has room to offer starting points.
    static let suggestionSubscriptionCeiling = 4
    /// Past this horizon "in N days" stops being useful and the date reads better.
    private static let relativeRenewalHorizon = 45

    init(
        period: Period,
        displayName: String,
        inputs: [Input],
        displayCurrency: String,
        previousPeriod: (amount: Decimal, label: String)?,
        conversionNote: String?,
        suggestions: [Suggestion],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) {
        self.period = period
        self.conversionNote = conversionNote
        self.suggestions = suggestions

        greeting = Self.greeting(for: displayName, at: referenceDate, calendar: calendar)
        monthTitle = "\(referenceDate.formatted(.dateTime.month(.wide))) overview"
        periodLabel = period == .month ? "This month" : "This year"

        let monthlyTotal = inputs.compactMap(\.convertedMonthlyCost).reduce(Decimal.zero, +)
        let yearlyTotal = monthlyTotal * 12
        let periodTotal = period == .month ? monthlyTotal : yearlyTotal
        totalText = periodTotal.currencyText(code: displayCurrency)

        let count = inputs.count
        subtitle =
            period == .month
            ? "About \(yearlyTotal.currencyText(code: displayCurrency)) a year at this rate"
            : "Across \(count) \(count == 1 ? "subscription" : "subscriptions") at today's prices"

        countLabel = count == 0 ? "Nothing tracked" : "\(count) active · by renewal"

        (deltaLabel, deltaDirection) = Self.delta(
            currentMonthly: monthlyTotal,
            previousPeriod: previousPeriod,
            period: period,
            displayCurrency: displayCurrency
        )

        segments = Self.segments(for: inputs, total: monthlyTotal)

        cards = Self.cards(
            for: inputs,
            period: period,
            displayCurrency: displayCurrency,
            referenceDate: referenceDate,
            calendar: calendar
        )

        nextCharge = Self.nextCharge(
            from: cards,
            inputs: inputs,
            displayCurrency: displayCurrency,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    // MARK: - Derivation

    private static func greeting(for name: String, at date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        return switch hour {
        case 5..<12: "Good morning, \(name)"
        case 12..<18: "Good afternoon, \(name)"
        default: "Good evening, \(name)"
        }
    }

    private static func delta(
        currentMonthly: Decimal,
        previousPeriod: (amount: Decimal, label: String)?,
        period: Period,
        displayCurrency: String
    ) -> (String?, SpendDirection) {
        guard let previousPeriod else { return (nil, .flat) }

        let change = currentMonthly - previousPeriod.amount
        guard change != 0 else {
            return ("same as \(previousPeriod.label)", .flat)
        }

        let scaled = period == .month ? change : change * 12
        let magnitude = (scaled < 0 ? -scaled : scaled).currencyText(code: displayCurrency)
        let sign = change > 0 ? "+" : "−"
        return ("\(sign)\(magnitude) since \(previousPeriod.label)", change > 0 ? .up : .down)
    }

    private static func segments(for inputs: [Input], total: Decimal) -> [Segment] {
        guard total > 0 else { return [] }

        let totals = inputs.reduce(into: [SubscriptionCategory: Decimal]()) { result, input in
            guard let cost = input.convertedMonthlyCost else { return }
            result[input.subscription.category, default: 0] += cost
        }

        return
            totals
            .map { category, amount in
                Segment(
                    category: category,
                    amount: amount,
                    fraction: (amount / total).doubleValue
                )
            }
            .sorted { lhs, rhs in
                lhs.amount == rhs.amount
                    ? lhs.category.rawValue < rhs.category.rawValue
                    : lhs.amount > rhs.amount
            }
    }

    private static func cards(
        for inputs: [Input],
        period: Period,
        displayCurrency: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> [Card] {
        inputs
            .map { input -> Card in
                let subscription = input.subscription
                let daysLeft = daysLeft(until: subscription.nextRenewalDate, from: referenceDate, calendar: calendar)
                let monthlyCost = input.convertedMonthlyCost ?? subscription.monthlyCost
                let periodCost = period == .month ? monthlyCost : monthlyCost * 12
                let showsNative =
                    subscription.currency != displayCurrency && input.convertedMonthlyCost != nil

                return Card(
                    subscription: subscription,
                    categoryLabel: subscription.category.title,
                    cadenceLabel: subscription.billingCycle.title.lowercased(),
                    periodPriceText: periodCost.currencyText(
                        code: input.convertedMonthlyCost == nil ? subscription.currency : displayCurrency
                    ),
                    nativePriceText: showsNative
                        ? subscription.price.currencyText(code: subscription.currency)
                        : nil,
                    perLabel: period == .month ? "per month" : "per year",
                    daysLeft: daysLeft,
                    renewLabel: renewLabel(
                        daysLeft: daysLeft,
                        renewalDate: subscription.nextRenewalDate
                    ),
                    cycleProgress: cycleProgress(
                        daysLeft: daysLeft,
                        cycle: subscription.billingCycle,
                        renewalDate: subscription.nextRenewalDate,
                        calendar: calendar
                    )
                )
            }
            .sorted { lhs, rhs in
                lhs.subscription.nextRenewalDate == rhs.subscription.nextRenewalDate
                    ? lhs.subscription.name.localizedCaseInsensitiveCompare(rhs.subscription.name) == .orderedAscending
                    : lhs.subscription.nextRenewalDate < rhs.subscription.nextRenewalDate
            }
    }

    private static func nextCharge(
        from cards: [Card],
        inputs: [Input],
        displayCurrency: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> NextCharge? {
        guard let card = cards.first(where: { $0.daysLeft >= 0 }) ?? cards.first else { return nil }
        let input = inputs.first { $0.subscription.id == card.subscription.id }
        let price = input?.convertedPrice ?? card.subscription.price
        let currency = input?.convertedPrice == nil ? card.subscription.currency : displayCurrency

        return NextCharge(
            subscriptionID: card.subscription.id,
            name: card.subscription.name,
            daysAway: card.daysLeft,
            dateLabel: card.subscription.nextRenewalDate.formatted(.dateTime.month(.abbreviated).day()),
            priceText: price.currencyText(code: currency)
        )
    }

    private static func daysLeft(until renewal: Date, from reference: Date, calendar: Calendar) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: reference),
            to: calendar.startOfDay(for: renewal)
        ).day ?? 0
    }

    private static func renewLabel(daysLeft: Int, renewalDate: Date) -> String {
        switch daysLeft {
        case ..<0: "past due"
        case 0: "today"
        case 1: "tomorrow"
        case 2...relativeRenewalHorizon: "in \(daysLeft) days"
        default: "on \(renewalDate.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }

    private static func cycleProgress(
        daysLeft: Int,
        cycle: BillingCycle,
        renewalDate: Date,
        calendar: Calendar
    ) -> Double {
        guard daysLeft > 0 else { return 1 }

        let length = cycleLength(for: cycle, endingOn: renewalDate, calendar: calendar)
        guard length > 0 else { return 1 }

        return min(max(1 - Double(daysLeft) / Double(length), 0), 1)
    }

    /// Length of the cycle that ends on `renewal`, so a 28-day February reads differently to a 31-day March.
    private static func cycleLength(for cycle: BillingCycle, endingOn renewal: Date, calendar: Calendar) -> Int {
        let start: Date? = switch cycle {
        case .weekly: calendar.date(byAdding: .day, value: -7, to: renewal)
        case .monthly: calendar.date(byAdding: .month, value: -1, to: renewal)
        case .quarterly: calendar.date(byAdding: .month, value: -3, to: renewal)
        case .yearly: calendar.date(byAdding: .year, value: -1, to: renewal)
        }
        guard let start else { return 0 }
        return calendar.dateComponents([.day], from: start, to: renewal).day ?? 0
    }
}

extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
