import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store
    @State private var period: Period = .month
    @State private var appeared = false
    @Namespace private var periodSelection

    private enum Period: String, CaseIterable {
        case month = "Month"
        case year = "Year"
    }

    private var displayedSpend: Decimal {
        period == .month ? store.monthlySpend : store.yearlySpend
    }

    private var soon: [Subscription] {
        store.activeSubscriptions
            .filter {
                let days = Calendar.current.dateComponents([.day], from: .now.startOfDay, to: $0.nextRenewalDate.startOfDay).day ?? 99
                return (0...7).contains(days)
            }
            .sorted { $0.nextRenewalDate < $1.nextRenewalDate }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 28)
                    .renewaEntrance(appeared, delay: 0.02)

                periodPicker
                    .padding(.bottom, 28)
                    .renewaEntrance(appeared, delay: 0.08)

                spending
                    .renewaEntrance(appeared, delay: 0.14)

                Divider()
                    .overlay(RenewaTheme.divider)
                    .padding(.vertical, 28)
                    .renewaEntrance(appeared, delay: 0.18, distance: 8)

                if !soon.isEmpty {
                    renewals
                        .padding(.bottom, 25)
                        .renewaEntrance(appeared, delay: 0.22)
                }

                subscriptions
                    .renewaEntrance(appeared, delay: 0.3)

                if !store.inactiveSubscriptions.isEmpty {
                    inactiveSubscriptions
                        .padding(.top, 28)
                        .renewaEntrance(appeared, delay: 0.36)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .refreshable {
            do {
                try await store.refreshData()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            appeared = true
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.renewa(17, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                Text("\(Date.now.formatted(.dateTime.month(.wide))) overview")
                    .font(.renewa(29, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
            }
            Spacer()
            ZStack {
                Circle()
                    .fill(store.profileAvatar.color)
                Text(initials)
                    .font(.renewa(21, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .scaleEffect(appeared ? 1 : 0.72)
            .rotationEffect(.degrees(appeared ? 0 : -12))
            .animation(RenewaMotion.gentle.delay(0.12), value: appeared)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases, id: \.self) { item in
                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                        period = item
                    }
                } label: {
                    Text(item.rawValue)
                        .font(.renewa(16, weight: .semibold))
                        .foregroundStyle(period == item ? RenewaTheme.ink : RenewaTheme.muted.opacity(0.6))
                        .frame(width: 94, height: 42)
                        .background {
                            if period == item {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(RenewaTheme.surface)
                                    .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "period", in: periodSelection)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RenewaTheme.divider.opacity(0.45), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var spending: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(period == .month ? "SPENDING THIS MONTH" : "SPENDING THIS YEAR")
                .font(.renewa(14, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(RenewaTheme.muted.opacity(0.65))

            HStack(alignment: .lastTextBaseline) {
                Text(displayedSpend.currencyText(code: store.defaultCurrency))
                    .font(.system(size: 55, weight: .medium, design: .serif))
                    .foregroundStyle(RenewaTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .contentTransition(.numericText(value: displayedSpend.doubleValue))
                Spacer()
                Label {
                    Text("Live data")
                } icon: {
                    HeroIcon(.checkCircle, style: .solid, size: 18)
                }
                    .font(.renewa(13, weight: .bold))
                    .foregroundStyle(RenewaTheme.sage)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(RenewaTheme.sage.opacity(0.1), in: Capsule())
            }

            Text(spendingSummary)
                .font(.renewa(16, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)

            categoryBar
        }
    }

    private var categoryBar: some View {
        let totals = categoryTotals
        let sum = totals.reduce(Decimal.zero) { $0 + $1.1 }

        return VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { index, item in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.0.color)
                            .frame(
                                width: appeared
                                    ? geometry.size.width * CGFloat((item.1 / max(sum, 0.01)).doubleValue)
                                    : 0
                            )
                            .animation(RenewaMotion.gentle.delay(0.18 + Double(index) * 0.06), value: appeared)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)

            HStack(spacing: 18) {
                ForEach(totals.prefix(3), id: \.0) { category, _ in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(category.color)
                            .frame(width: 11, height: 11)
                        Text(category.title)
                            .font(.renewa(14, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }
            }
        }
    }

    private var renewals: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Renewing soon")
                    .font(.renewa(20, weight: .bold))
                Spacer()
                Text("\(soon.count) this week")
                    .font(.renewa(15, weight: .bold))
                    .foregroundStyle(RenewaTheme.coral)
            }

            ForEach(Array(soon.prefix(2).enumerated()), id: \.element.id) { index, subscription in
                SubscriptionRow(subscription: subscription, showsRenewal: true)
                    .renewaEntrance(appeared, delay: 0.27 + Double(index) * 0.06, distance: 10)
            }
        }
    }

    private var subscriptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("All subscriptions")
                .font(.renewa(20, weight: .bold))

            if store.activeSubscriptions.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No subscriptions yet")
                    } icon: {
                        HeroIcon(.sparkles, style: .solid, size: 34)
                    }
                } description: {
                    Text("Add one manually or scan your inbox.")
                }
                .foregroundStyle(RenewaTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(
                    Array(
                        store.activeSubscriptions
                            .sorted { $0.nextRenewalDate < $1.nextRenewalDate }
                            .enumerated()
                    ),
                    id: \.element.id
                ) { index, subscription in
                    SubscriptionRow(subscription: subscription)
                        .renewaEntrance(appeared, delay: 0.34 + Double(index) * 0.045, distance: 10)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await store.remove(subscription) }
                            } label: {
                                Label {
                                    Text("Remove")
                                } icon: {
                                    HeroIcon(.trash, size: 18)
                                }
                            }
                        }
                }
            }
        }
    }

    private var inactiveSubscriptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inactive")
                .font(.renewa(20, weight: .bold))

            ForEach(
                Array(
                    store.inactiveSubscriptions
                        .sorted {
                            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
                        }
                        .enumerated()
                ),
                id: \.element.id
            ) { index, subscription in
                SubscriptionRow(subscription: subscription, statusText: subscription.status.title)
                    .opacity(0.58)
                    .renewaEntrance(appeared, delay: 0.4 + Double(index) * 0.045, distance: 10)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await store.remove(subscription) }
                        } label: {
                            Label {
                                Text("Delete permanently")
                            } icon: {
                                HeroIcon(.trash, size: 18)
                            }
                        }
                    }
            }
        }
    }

    private var categoryTotals: [(SubscriptionCategory, Decimal)] {
        let grouped = Dictionary(
            grouping: store.activeSubscriptions.filter { $0.currency == store.defaultCurrency },
            by: \.category
        )
            .mapValues { $0.reduce(Decimal.zero) { $0 + $1.monthlyCost } }
        let sorted = grouped.sorted { $0.value > $1.value }
        return sorted.isEmpty ? [(.other, 1)] : sorted
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return switch hour {
        case 5..<12: "Good morning, \(store.displayName)"
        case 12..<18: "Good afternoon, \(store.displayName)"
        default: "Good evening, \(store.displayName)"
        }
    }

    private var initials: String {
        let words = store.displayName.split(separator: " ").prefix(2)
        let initials = words.compactMap(\.first).map(String.init).joined()
        return initials.isEmpty ? "R" : initials.uppercased()
    }

    private var spendingSummary: String {
        var text = "≈ \(store.yearlySpend.currencyText(code: store.defaultCurrency)) a year · \(store.activeSubscriptions.count) active subscriptions"
        if store.foreignCurrencySubscriptionCount > 0 {
            text += " · \(store.foreignCurrencySubscriptionCount) shown separately"
        }
        return text
    }
}

struct SubscriptionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let subscription: Subscription
    var showsRenewal = false
    var statusText: String?

    var body: some View {
        HStack(spacing: 16) {
            SubscriptionBrandIcon(subscription: subscription)

            VStack(alignment: .leading, spacing: 3) {
                Text(subscription.name)
                    .font(.renewa(18, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(statusText ?? (showsRenewal ? subscription.renewalDescription : subscription.billingCycle.title))
                    .font(.renewa(14, weight: .medium))
                    .foregroundStyle(showsRenewal ? RenewaTheme.coral : RenewaTheme.muted.opacity(0.75))
            }
            Spacer()
            Text(subscription.price.currencyText(code: subscription.currency))
                .font(.renewa(17, weight: .medium))
                .foregroundStyle(RenewaTheme.ink)
        }
        .contentShape(Rectangle())
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                )
        )
    }
}

private extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
