import SwiftUI

struct PaymentCalendarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var focusedMonth = Self.currentMonth
    @State private var selectedDate = Date.now.startOfDay
    @State private var monthNavigationDirection: CalendarNavigationDirection = .forward
    @Namespace private var selectedDayIndicator

    private static var currentMonth: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.calendar, .year, .month], from: .now)) ?? .now
    }

    private let calendar = Calendar.current

    private var projector: SubscriptionDeadlineProjector {
        SubscriptionDeadlineProjector(calendar: calendar)
    }

    private var activeSubscriptions: [Subscription] {
        store.activeSubscriptions
    }

    private var focusedMonthStart: Date {
        calendar.date(from: calendar.dateComponents([.calendar, .year, .month], from: focusedMonth)) ?? focusedMonth.startOfDay
    }

    private var visibleDeadlines: [SubscriptionDeadline] {
        projector.deadlines(for: activeSubscriptions, inMonthContaining: focusedMonthStart)
    }

    private var deadlinesByDay: [Date: [SubscriptionDeadline]] {
        Dictionary(grouping: visibleDeadlines) { deadline in
            calendar.startOfDay(for: deadline.date)
        }
    }

    private var selectedDeadlines: [SubscriptionDeadline] {
        deadlinesByDay[calendar.startOfDay(for: selectedDate)] ?? []
    }

    private var nextThirtyDays: [SubscriptionDeadline] {
        let end = calendar.date(byAdding: .day, value: 30, to: Date.now.startOfDay) ?? .now
        return projector.deadlines(for: activeSubscriptions, from: Date.now.startOfDay, until: end)
    }

    private var nextThirtyDayTotal: Decimal {
        nextThirtyDays
            .compactMap { store.convertedAmount($0.subscription.price, from: $0.subscription.currency) }
            .reduce(0, +)
    }

    private var hasUnavailableThirtyDayTotal: Bool {
        nextThirtyDays.contains {
            store.convertedAmount($0.subscription.price, from: $0.subscription.currency) == nil
        }
    }

    private var selectedDateTotal: Decimal? {
        guard !selectedDeadlines.isEmpty else { return nil }
        let converted = selectedDeadlines.compactMap {
            store.convertedAmount($0.subscription.price, from: $0.subscription.currency)
        }
        guard converted.count == selectedDeadlines.count else { return nil }
        return converted.reduce(0, +)
    }

    private var calendarDays: [Date?] {
        let dayCount = calendar.range(of: .day, in: .month, for: focusedMonthStart)?.count ?? 0
        let firstWeekday = calendar.component(.weekday, from: focusedMonthStart)
        let leadingCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dates = (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: focusedMonthStart)
        }
        let leading = Array(repeating: Date?.none, count: leadingCount)
        let trailingCount = (7 - ((leading.count + dates.count) % 7)) % 7
        return leading + dates.map(Optional.some) + Array(repeating: Date?.none, count: trailingCount)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let firstIndex = max(0, calendar.firstWeekday - 1)
        return Array(symbols[firstIndex...]) + Array(symbols[..<firstIndex])
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                    .renewaEntrance(appeared, delay: 0.02)

                summaryCard
                    .renewaEntrance(appeared, delay: 0.07)

                calendarCard
                    .renewaEntrance(appeared, delay: 0.12)

                selectedDateContainer
                    .renewaEntrance(appeared, delay: 0.16, distance: 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(RenewaTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            appeared = true
        }
    }

    private var calendarAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.2)
    }

    private var monthTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: monthNavigationDirection.insertionEdge).combined(with: .opacity),
            removal: .move(edge: monthNavigationDirection.removalEdge).combined(with: .opacity)
        )
    }

    private var selectedDateTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .bottom)),
                removal: .opacity
            )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Payment calendar")
                .font(.renewa(32, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
            Text("Plan around every subscription renewal.")
                .font(.renewa(15))
                .foregroundStyle(RenewaTheme.muted)
        }
    }

    private var summaryCard: some View {
        RenewaCard {
            HStack(spacing: 18) {
                summaryMetric(
                    value: "\(nextThirtyDays.count)",
                    label: nextThirtyDays.count == 1 ? "payment in 30 days" : "payments in 30 days"
                )

                Rectangle()
                    .fill(RenewaTheme.divider)
                    .frame(width: 1, height: 48)

                summaryMetric(
                    value: hasUnavailableThirtyDayTotal
                        ? "—"
                        : nextThirtyDayTotal.currencyText(code: store.defaultCurrency),
                    label: hasUnavailableThirtyDayTotal
                        ? "total unavailable"
                        : "due in 30 days"
                )
            }
        }
    }

    private func summaryMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.renewa(21, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.renewa(12, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calendarCard: some View {
        RenewaCard {
            VStack(spacing: 18) {
                monthNavigation
                weekdayHeader
                animatedMonthGrid
            }
        }
    }

    private var monthNavigation: some View {
        HStack(spacing: 10) {
            monthButton(direction: -1, accessibilityLabel: "Previous month")

            Text(focusedMonthStart.formatted(.dateTime.month(.wide).year()))
                .font(.renewa(19, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)

            Button("Today") {
                returnToToday()
            }
            .font(.renewa(13, weight: .bold))
            .foregroundStyle(RenewaTheme.sage)
            .buttonStyle(PressScaleStyle())
            .accessibilityHint("Returns to the current month and today")

            monthButton(direction: 1, accessibilityLabel: "Next month")
        }
    }

    private func monthButton(direction: Int, accessibilityLabel: String) -> some View {
        Button {
            changeMonth(by: direction)
        } label: {
            HeroIcon(.chevronRight, size: 16)
                .foregroundStyle(RenewaTheme.ink)
                .rotationEffect(.degrees(direction < 0 ? 180 : 0))
                .frame(width: 30, height: 30)
                .background(RenewaTheme.background.opacity(0.75), in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: gridColumns, spacing: 4) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol.prefix(1).uppercased())
                    .font(.renewa(11, weight: .bold))
                    .foregroundStyle(RenewaTheme.muted)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 7) {
            ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayButton(for: date)
                } else {
                    Color.clear
                        .frame(height: 46)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var animatedMonthGrid: some View {
        ZStack {
            monthGrid
                .id(focusedMonthStart)
                .transition(monthTransition)
        }
        .clipped()
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    private func dayButton(for date: Date) -> some View {
        let day = calendar.startOfDay(for: date)
        let deadlines = deadlinesByDay[day] ?? []
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)

        return Button {
            select(day)
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.day()))
                    .font(.renewa(15, weight: .bold))
                    .foregroundStyle(isSelected ? .white : RenewaTheme.ink)
                    .frame(maxWidth: .infinity)

                deadlineIndicator(count: deadlines.count, isSelected: isSelected)
            }
            .frame(height: 46)
            .background {
                selectedDayBackground(isSelected: isSelected)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isToday && !isSelected ? RenewaTheme.sage.opacity(0.75) : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(dayAccessibilityLabel(for: day, deadlines: deadlines))
        .accessibilityHint("Shows subscription payments due on this date")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func selectedDayBackground(isSelected: Bool) -> some View {
        if isSelected {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RenewaTheme.sage)

            if reduceMotion {
                shape
            } else {
                shape.matchedGeometryEffect(
                    id: "selected-calendar-day-\(focusedMonthStart.timeIntervalSinceReferenceDate)",
                    in: selectedDayIndicator
                )
            }
        }
    }

    @ViewBuilder
    private func deadlineIndicator(count: Int, isSelected: Bool) -> some View {
        if count == 1 {
            Circle()
                .fill(isSelected ? .white.opacity(0.9) : RenewaTheme.coral)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        } else if count > 1 {
            Text("\(count)")
                .font(.renewa(9, weight: .bold))
                .foregroundStyle(isSelected ? RenewaTheme.sage : .white)
                .frame(minWidth: 15, minHeight: 15)
                .background(isSelected ? .white : RenewaTheme.coral, in: Capsule())
                .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(height: 5)
                .accessibilityHidden(true)
        }
    }

    private var selectedDateContainer: some View {
        ZStack {
            selectedDateSection
                .id(selectedDate)
                .transition(selectedDateTransition)
        }
    }

    private var selectedDateSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.renewa(20, weight: .bold))
                        .foregroundStyle(RenewaTheme.ink)
                    Text(selectedDeadlines.isEmpty ? "No payments due" : "\(selectedDeadlines.count) payment\(selectedDeadlines.count == 1 ? "" : "s") due")
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                }

                Spacer()

                if let selectedDateTotal {
                    Text(selectedDateTotal.currencyText(code: store.defaultCurrency))
                        .font(.renewa(15, weight: .bold))
                        .foregroundStyle(RenewaTheme.sage)
                }
            }

            RenewaCard {
                if selectedDeadlines.isEmpty {
                    emptySelectedDateState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(selectedDeadlines.enumerated()), id: \.element.id) { index, deadline in
                            paymentRow(deadline)

                            if index < selectedDeadlines.count - 1 {
                                Divider()
                                    .overlay(RenewaTheme.divider)
                                    .padding(.leading, 58)
                                    .padding(.vertical, 13)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var emptySelectedDateState: some View {
        HStack(spacing: 13) {
            HeroIcon(.checkCircle, size: 27)
                .foregroundStyle(RenewaTheme.sage)
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing due")
                    .font(.renewa(16, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Text("No subscription payments are scheduled for this day.")
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func paymentRow(_ deadline: SubscriptionDeadline) -> some View {
        let subscription = deadline.subscription

        return HStack(spacing: 13) {
            SubscriptionBrandIcon(subscription: subscription, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name)
                    .font(.renewa(16, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                    .lineLimit(1)
                Text("\(subscription.billingCycle.title) • \(dueDescription(for: deadline.date))")
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(isDueSoon(deadline.date) ? RenewaTheme.coral : RenewaTheme.muted)
            }

            Spacer(minLength: 6)
            paymentPrice(subscription)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func paymentPrice(_ subscription: Subscription) -> some View {
        if subscription.currency == store.defaultCurrency {
            Text(subscription.price.currencyText(code: subscription.currency))
                .font(.renewa(15, weight: .semibold))
                .foregroundStyle(RenewaTheme.ink)
        } else if let converted = store.convertedAmount(subscription.price, from: subscription.currency) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("≈ \(converted.currencyText(code: store.defaultCurrency))")
                    .font(.renewa(15, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(subscription.price.currencyText(code: subscription.currency))
                    .font(.renewa(11, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
            }
        } else {
            Text(subscription.price.currencyText(code: subscription.currency))
                .font(.renewa(15, weight: .semibold))
                .foregroundStyle(RenewaTheme.ink)
        }
    }

    private func dueDescription(for date: Date) -> String {
        let days = calendar.dateComponents([.day], from: Date.now.startOfDay, to: date.startOfDay).day ?? 0
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        if days > 1 { return "Due in \(days) days" }
        return "Due \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func isDueSoon(_ date: Date) -> Bool {
        let days = calendar.dateComponents([.day], from: Date.now.startOfDay, to: date.startOfDay).day ?? 99
        return (0...7).contains(days)
    }

    private func dayAccessibilityLabel(for date: Date, deadlines: [SubscriptionDeadline]) -> String {
        let dateText = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        guard !deadlines.isEmpty else { return "\(dateText), no subscription payments due" }

        let paymentText = "\(deadlines.count) subscription payment\(deadlines.count == 1 ? "" : "s") due"
        let converted = deadlines.compactMap {
            store.convertedAmount($0.subscription.price, from: $0.subscription.currency)
        }
        guard converted.count == deadlines.count else { return "\(dateText), \(paymentText), total unavailable" }
        let total = converted.reduce(0, +).currencyText(code: store.defaultCurrency)
        return "\(dateText), \(paymentText), \(total) due"
    }

    private func select(_ date: Date) {
        guard !calendar.isDate(selectedDate, inSameDayAs: date) else { return }
        withAnimation(calendarAnimation) {
            selectedDate = calendar.startOfDay(for: date)
        }
    }

    private func changeMonth(by offset: Int) {
        guard let month = calendar.date(byAdding: .month, value: offset, to: focusedMonthStart) else { return }

        withAnimation(calendarAnimation) {
            monthNavigationDirection = offset > 0 ? .forward : .backward
            focusedMonth = month
            if !calendar.isDate(selectedDate, equalTo: month, toGranularity: .month) {
                selectedDate = month.startOfDay
            }
        }
    }

    private func returnToToday() {
        let today = Date.now.startOfDay
        let todayMonth = Self.currentMonth

        withAnimation(calendarAnimation) {
            if !calendar.isDate(focusedMonthStart, equalTo: todayMonth, toGranularity: .month) {
                monthNavigationDirection = todayMonth > focusedMonthStart ? .forward : .backward
                focusedMonth = todayMonth
            }
            selectedDate = today
        }
    }
}

private enum CalendarNavigationDirection {
    case forward
    case backward

    var insertionEdge: Edge {
        self == .forward ? .trailing : .leading
    }

    var removalEdge: Edge {
        self == .forward ? .leading : .trailing
    }
}
