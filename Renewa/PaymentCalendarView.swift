import SwiftUI

struct PaymentCalendarView: View {
    @Environment(AppStore.self) private var store
    @State private var appeared = false

    private var upcomingPayments: [Subscription] {
        store.activeSubscriptions
            .filter { $0.nextRenewalDate >= Date.now.startOfDay }
            .sorted { $0.nextRenewalDate < $1.nextRenewalDate }
    }

    private var monthGroups: [PaymentMonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: upcomingPayments) { subscription in
            let components = calendar.dateComponents(
                [.calendar, .year, .month],
                from: subscription.nextRenewalDate
            )
            return components.date ?? subscription.nextRenewalDate.startOfDay
        }

        return grouped
            .map { PaymentMonthGroup(month: $0.key, payments: $0.value) }
            .sorted { $0.month < $1.month }
    }

    private var nextThirtyDays: [Subscription] {
        let limit = Calendar.current.date(byAdding: .day, value: 30, to: Date.now.startOfDay) ?? .now
        return upcomingPayments.filter { $0.nextRenewalDate <= limit }
    }

    private var nextThirtyDayTotal: Decimal {
        nextThirtyDays
            .compactMap { store.convertedAmount($0.price, from: $0.currency) }
            .reduce(0, +)
    }

    private var hasUnavailableThirtyDayTotal: Bool {
        nextThirtyDays.contains {
            store.convertedAmount($0.price, from: $0.currency) == nil
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header
                    .renewaEntrance(appeared, delay: 0.02)

                summaryCard
                    .renewaEntrance(appeared, delay: 0.08)

                if monthGroups.isEmpty {
                    emptyState
                        .renewaEntrance(appeared, delay: 0.14)
                } else {
                    ForEach(Array(monthGroups.enumerated()), id: \.element.id) { index, group in
                        monthSection(group)
                            .renewaEntrance(
                                appeared,
                                delay: 0.14 + min(Double(index) * 0.05, 0.25),
                                distance: 12
                            )
                    }
                }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming payments")
                .font(.renewa(32, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
            Text("Your next subscription charges, organized by date.")
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

    private func monthSection(_ group: PaymentMonthGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.month.formatted(.dateTime.month(.wide).year()))
                    .font(.renewa(20, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Spacer()
                Text("\(group.payments.count)")
                    .font(.renewa(14, weight: .bold))
                    .foregroundStyle(RenewaTheme.sage)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RenewaTheme.sage.opacity(0.12), in: Capsule())
            }

            RenewaCard {
                VStack(spacing: 0) {
                    ForEach(Array(group.payments.enumerated()), id: \.element.id) { index, subscription in
                        paymentRow(subscription)

                        if index < group.payments.count - 1 {
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

    private func paymentRow(_ subscription: Subscription) -> some View {
        HStack(spacing: 13) {
            dateBadge(subscription.nextRenewalDate)

            SubscriptionBrandIcon(subscription: subscription, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name)
                    .font(.renewa(16, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                    .lineLimit(1)
                Text(subscription.renewalDescription)
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(isDueSoon(subscription) ? RenewaTheme.coral : RenewaTheme.muted)
            }

            Spacer(minLength: 6)
            paymentPrice(subscription)
        }
        .accessibilityElement(children: .combine)
    }

    private func dateBadge(_ date: Date) -> some View {
        VStack(spacing: 1) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.renewa(10, weight: .bold))
                .foregroundStyle(RenewaTheme.muted)
            Text(date.formatted(.dateTime.day()))
                .font(.renewa(21, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
        }
        .frame(width: 44, height: 48)
        .background(RenewaTheme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var emptyState: some View {
        RenewaCard {
            VStack(spacing: 13) {
                HeroIcon(.calendar, size: 34)
                    .foregroundStyle(RenewaTheme.sage)
                Text("No upcoming payments")
                    .font(.renewa(18, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Text("Active subscriptions with future renewal dates will appear here.")
                    .font(.renewa(14))
                    .foregroundStyle(RenewaTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private func isDueSoon(_ subscription: Subscription) -> Bool {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Date.now.startOfDay,
            to: subscription.nextRenewalDate.startOfDay
        ).day ?? 99
        return (0...7).contains(days)
    }
}

private struct PaymentMonthGroup: Identifiable {
    let month: Date
    let payments: [Subscription]

    var id: Date { month }
}
