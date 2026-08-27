import Foundation

/// The recorded spending history behind Insights: the month strip, the figures for the month the
/// reader has scrubbed to, and the category breakdown beneath it. Pure, so the arithmetic — which
/// is the whole point of the screen — stays testable.
struct SpendHistoryPresentationState: Equatable {
    /// One recorded month, already reduced to the display currency.
    struct Input: Equatable {
        let periodStart: Date
        let total: Decimal
        let categoryTotals: [SubscriptionCategory: Decimal]

        init(periodStart: Date, total: Decimal, categoryTotals: [SubscriptionCategory: Decimal]) {
            self.periodStart = periodStart
            self.total = total
            self.categoryTotals = categoryTotals
        }
    }

    /// A subscription sitting inside a category today, listed when a row is opened.
    struct LineItem: Equatable, Identifiable {
        let id: UUID
        let name: String
        let priceText: String
    }

    enum Direction: Equatable {
        case up
        case down
        case flat
        /// Nothing to compare against — the first month on record.
        case unknown
    }

    struct Month: Equatable, Identifiable {
        let periodStart: Date
        let shortLabel: String
        let fullLabel: String
        let totalText: String
        /// Position within the plotted series. Both 0...1, with `y` measured upwards from the low point.
        let x: Double
        let y: Double

        var id: Date { periodStart }
    }

    struct CategoryRow: Equatable, Identifiable {
        let category: SubscriptionCategory
        let amountText: String
        let shareLabel: String
        /// Bar width relative to the largest row, so the biggest category always fills its track.
        let barFraction: Double
        /// How this category moved against the month before, when there is one to compare to.
        let changeLabel: String?
        let changeDirection: Direction
        let items: [LineItem]

        var id: SubscriptionCategory { category }

        var isExpandable: Bool { changeLabel != nil || !items.isEmpty }

        var accessibilityLabel: String {
            var parts = [category.title, amountText, "\(shareLabel) of the month"]
            if let changeLabel { parts.append(changeLabel) }
            return parts.joined(separator: ", ")
        }
    }

    /// Six months is what fits across a phone before the strip stops being tappable.
    static let windowLength = 6

    let months: [Month]
    let selectedIndex: Int
    /// Chip beside the title, naming how much history is actually on record.
    let windowLabel: String
    let selectedTitle: String
    let selectedTotalText: String
    let deltaLabel: String
    let deltaDirection: Direction
    let categories: [CategoryRow]

    var selectedMonth: Month? {
        months.indices.contains(selectedIndex) ? months[selectedIndex] : nil
    }

    var isEmpty: Bool { months.isEmpty }

    /// Two points is the minimum that draws a line rather than a dot.
    var hasTrendLine: Bool { months.count >= 2 }

    /// - Parameters:
    ///   - inputs: Recorded months in any order; only the most recent `windowLength` are plotted.
    ///   - selectedIndex: Index into the plotted window, or `nil` for the latest month.
    ///   - currentLineItems: What is tracked in each category right now. Only attached to the
    ///     current calendar month, because closed months keep totals and not their line items.
    init(
        inputs: [Input],
        selectedIndex: Int? = nil,
        displayCurrency: String,
        currentLineItems: [SubscriptionCategory: [LineItem]] = [:],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) {
        let window = inputs.sorted { $0.periodStart < $1.periodStart }.suffix(Self.windowLength)
        let ordered = Array(window)

        months = Self.months(for: ordered, displayCurrency: displayCurrency, calendar: calendar)

        let clamped = min(max(selectedIndex ?? (ordered.count - 1), 0), max(ordered.count - 1, 0))
        self.selectedIndex = ordered.isEmpty ? 0 : clamped

        windowLabel =
            switch ordered.count {
            case 0: "No history yet"
            case 1: "This month"
            default: "Last \(ordered.count) months"
            }

        guard ordered.indices.contains(self.selectedIndex) else {
            selectedTitle = ""
            selectedTotalText = Decimal.zero.currencyText(code: displayCurrency)
            deltaLabel = ""
            deltaDirection = .unknown
            categories = []
            return
        }

        let selected = ordered[self.selectedIndex]
        let previous = self.selectedIndex > 0 ? ordered[self.selectedIndex - 1] : nil

        selectedTitle = Self.title(for: selected.periodStart, referenceDate: referenceDate, calendar: calendar)
        selectedTotalText = selected.total.currencyText(code: displayCurrency)

        (deltaLabel, deltaDirection) = Self.delta(
            current: selected.total,
            previous: previous.map { ($0.total, Self.shortLabel(for: $0.periodStart, calendar: calendar)) },
            displayCurrency: displayCurrency
        )

        let isCurrentMonth = calendar.isDate(
            selected.periodStart,
            equalTo: referenceDate,
            toGranularity: .month
        )

        categories = Self.categories(
            for: selected,
            previous: previous,
            displayCurrency: displayCurrency,
            lineItems: isCurrentMonth ? currentLineItems : [:],
            calendar: calendar
        )
    }

    // MARK: - Derivation

    private static func months(
        for inputs: [Input],
        displayCurrency: String,
        calendar: Calendar
    ) -> [Month] {
        let totals = inputs.map(\.total)
        let low = totals.min() ?? 0
        let high = totals.max() ?? 0
        let span = (high - low).doubleValue

        return inputs.enumerated().map { index, input in
            Month(
                periodStart: input.periodStart,
                shortLabel: shortLabel(for: input.periodStart, calendar: calendar),
                fullLabel: input.periodStart.formatted(style(for: calendar).month(.wide)),
                totalText: input.total.currencyText(code: displayCurrency),
                x: inputs.count > 1 ? Double(index) / Double(inputs.count - 1) : 0.5,
                // A flat series sits on the mid-line rather than collapsing onto the floor.
                y: span > 0 ? (input.total - low).doubleValue / span : 0.5
            )
        }
    }

    /// A month name means nothing without the zone it was bucketed in — a period that starts at
    /// midnight UTC is the month before in half the world.
    private static func style(for calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    }

    private static func shortLabel(for date: Date, calendar: Calendar) -> String {
        date.formatted(style(for: calendar).month(.abbreviated))
    }

    private static func title(for date: Date, referenceDate: Date, calendar: Calendar) -> String {
        let sameYear = calendar.isDate(date, equalTo: referenceDate, toGranularity: .year)
        return sameYear
            ? date.formatted(style(for: calendar).month(.wide))
            : date.formatted(style(for: calendar).month(.wide).year())
    }

    private static func delta(
        current: Decimal,
        previous: (total: Decimal, label: String)?,
        displayCurrency: String
    ) -> (String, Direction) {
        guard let previous else { return ("first month recorded", .unknown) }

        let change = current - previous.total
        guard change != 0 else { return ("same as \(previous.label)", .flat) }

        let magnitude = (change < 0 ? -change : change).currencyText(code: displayCurrency)
        let sign = change > 0 ? "+" : "−"
        return ("\(sign)\(magnitude) from \(previous.label)", change > 0 ? .up : .down)
    }

    private static func categories(
        for month: Input,
        previous: Input?,
        displayCurrency: String,
        lineItems: [SubscriptionCategory: [LineItem]],
        calendar: Calendar
    ) -> [CategoryRow] {
        let entries = month.categoryTotals.filter { $0.value > 0 }
        guard !entries.isEmpty else { return [] }

        let total = entries.values.reduce(Decimal.zero, +)
        let largest = entries.values.max() ?? 0

        return
            entries
            .map { category, amount in
                let change = self.change(
                    for: category,
                    amount: amount,
                    previous: previous,
                    displayCurrency: displayCurrency,
                    calendar: calendar
                )
                return CategoryRow(
                    category: category,
                    amountText: amount.currencyText(code: displayCurrency),
                    shareLabel: total > 0 ? "\(Int(((amount / total).doubleValue * 100).rounded()))%" : "—",
                    barFraction: largest > 0 ? (amount / largest).doubleValue : 0,
                    changeLabel: change.label,
                    changeDirection: change.direction,
                    items: lineItems[category] ?? []
                )
            }
            .sorted { lhs, rhs in
                lhs.barFraction == rhs.barFraction
                    ? lhs.category.rawValue < rhs.category.rawValue
                    : lhs.barFraction > rhs.barFraction
            }
    }

    private static func change(
        for category: SubscriptionCategory,
        amount: Decimal,
        previous: Input?,
        displayCurrency: String,
        calendar: Calendar
    ) -> (label: String?, direction: Direction) {
        guard let previous else { return (nil, .unknown) }
        let label = shortLabel(for: previous.periodStart, calendar: calendar)

        guard let before = previous.categoryTotals[category], before > 0 else {
            return ("new since \(label)", .up)
        }

        let change = amount - before
        guard change != 0 else { return ("unchanged from \(label)", .flat) }

        let magnitude = (change < 0 ? -change : change).currencyText(code: displayCurrency)
        return ("\(change > 0 ? "+" : "−")\(magnitude) from \(label)", change > 0 ? .up : .down)
    }

    /// Which month the reader is pointing at, given how far across the plot they have dragged.
    static func index(forXFraction fraction: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let scaled = (fraction * Double(count - 1)).rounded()
        return min(max(Int(scaled), 0), count - 1)
    }
}
