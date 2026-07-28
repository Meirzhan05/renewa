import Charts
import SwiftUI

struct InsightsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var categoryTotals: [(SubscriptionCategory, Decimal)] {
        let values = store.activeSubscriptions.compactMap { subscription -> (SubscriptionCategory, Decimal)? in
            guard let amount = store.convertedMonthlyCost(for: subscription) else { return nil }
            return (subscription.category, amount)
        }
        return Dictionary(grouping: values, by: \.0)
            .map { category, values in (category, values.reduce(0) { $0 + $1.1 }) }
            .sorted { $0.1 > $1.1 }
    }

    private var upcomingRenewals: [Subscription] {
        let limit = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        return store.activeSubscriptions
            .filter { $0.nextRenewalDate >= .now.startOfDay && $0.nextRenewalDate <= limit }
            .sorted { $0.nextRenewalDate < $1.nextRenewalDate }
    }

    private var trendPoints: [TrendPoint] {
        let usable = store.spendingSnapshots.compactMap { snapshot -> (Date, Decimal)? in
            guard let amount = store.convertedMonthlyCost(for: snapshot) else { return nil }
            return (snapshot.periodStart, amount)
        }
        return Dictionary(grouping: usable, by: \.0)
            .map { date, values in TrendPoint(date: date, value: values.reduce(0) { $0 + $1.1 }) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                commitmentCard
                aiSummary
                trendSection
                categorySection
                renewalSection
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .task { await store.loadInsights() }
        .onAppear { appeared = true }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Insights")
                    .font(.renewa(32, weight: .bold))
                Text("A clearer view of your commitments.")
                    .font(.renewa(15))
                    .foregroundStyle(RenewaTheme.muted)
            }
            Spacer()
            Button {
                Task { await store.loadInsights(force: true) }
            } label: {
                HeroIcon(.arrowPath, size: 20)
                    .foregroundStyle(RenewaTheme.ink)
                    .frame(width: 40, height: 40)
                    .background(RenewaTheme.surface, in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(store.isLoadingInsights)
            .accessibilityLabel("Refresh insights")
        }
        .padding(.top, 18)
        .renewaEntrance(appeared, delay: 0.02)
    }

    private var commitmentCard: some View {
        RenewaCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Annual commitment")
                    .font(.renewa(15, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                Text(store.yearlySpend.currencyText(code: store.defaultCurrency))
                    .font(.system(size: 43, weight: .medium, design: .serif))
                    .contentTransition(.numericText())
                Text("That’s (store.monthlySpend.currencyText(code: store.defaultCurrency)) every month.")
                    .font(.renewa(15))
                    .foregroundStyle(RenewaTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .renewaEntrance(appeared, delay: 0.07)
    }

    @ViewBuilder
    private var aiSummary: some View {
        if let report = store.insightReport {
            RenewaCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 9) {
                        HeroIcon(.sparkles, style: .solid, size: 21)
                            .foregroundStyle(RenewaTheme.sage)
                        Text(report.isAIGenerated ? "Renewa’s read" : "Your subscription snapshot")
                            .font(.renewa(16, weight: .bold))
                    }
                    Text(report.summary)
                        .font(.renewa(16))
                        .foregroundStyle(RenewaTheme.ink)
                    ForEach(report.cards) { card in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title).font(.renewa(14, weight: .semibold))
                            Text(card.body).font(.renewa(14)).foregroundStyle(RenewaTheme.muted)
                            Text("Based on your stored subscriptions and billing activity")
                                .font(.renewa(11, weight: .medium))
                                .foregroundStyle(RenewaTheme.muted.opacity(0.82))
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .renewaEntrance(appeared, delay: 0.12)
        } else if store.isLoadingInsights {
            RenewaCard {
                HStack(spacing: 12) {
                    ProgressView().tint(RenewaTheme.sage)
                    Text("Reading your subscription patterns…")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                }
            }
        } else if let message = store.insightsErrorMessage {
            RenewaCard {
                HStack(alignment: .top, spacing: 12) {
                    HeroIcon(.lightBulb, size: 23).foregroundStyle(RenewaTheme.sand)
                    Text(message).font(.renewa(14)).foregroundStyle(RenewaTheme.muted)
                }
            }
        }
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Monthly commitment")
                .font(.renewa(20, weight: .bold))
            if trendPoints.count >= 2 {
                RenewaCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Chart(trendPoints) { point in
                            AreaMark(
                                x: .value("Month", point.date, unit: .month),
                                y: .value("Monthly spend", point.value.asDouble)
                            )
                            .foregroundStyle(RenewaTheme.sage.opacity(0.16))
                            LineMark(
                                x: .value("Month", point.date, unit: .month),
                                y: .value("Monthly spend", point.value.asDouble)
                            )
                            .foregroundStyle(RenewaTheme.sage)
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            PointMark(
                                x: .value("Month", point.date, unit: .month),
                                y: .value("Monthly spend", point.value.asDouble)
                            )
                            .foregroundStyle(RenewaTheme.sage)
                        }
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                        .frame(height: 170)
                        Text("Showing persisted monthly commitments in (store.defaultCurrency).")
                            .font(.renewa(12))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Monthly commitment trend with (trendPoints.count) monthly data points in (store.defaultCurrency)")
            } else {
                emptyCard("Your trend will appear after two monthly snapshots. We never estimate missing history.", icon: .chartBar)
            }
        }
        .renewaEntrance(appeared, delay: 0.16)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Where it goes")
                .font(.renewa(20, weight: .bold))
            if categoryTotals.isEmpty {
                emptyCard("Add an active subscription to see your category mix.", icon: .chartBar)
            } else {
                RenewaCard {
                    VStack(spacing: 16) {
                        Chart(categoryTotals, id: \.0) { item in
                            SectorMark(
                                angle: .value("Monthly cost", item.1.asDouble),
                                innerRadius: .ratio(0.63),
                                angularInset: 2
                            )
                            .foregroundStyle(item.0.color)
                        }
                        .frame(height: 190)
                        .accessibilityHidden(true)
                        VStack(spacing: 10) {
                            ForEach(categoryTotals, id: \.0) { item in
                                HStack {
                                    Circle().fill(item.0.color).frame(width: 9, height: 9)
                                    Text(item.0.title).font(.renewa(14, weight: .medium))
                                    Spacer()
                                    Text(item.1.currencyText(code: store.defaultCurrency)).font(.renewa(14, weight: .semibold))
                                }
                            }
                        }
                    }
                }
            }
        }
        .renewaEntrance(appeared, delay: 0.2)
    }

    private var renewalSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Next 30 days")
                .font(.renewa(20, weight: .bold))
            if upcomingRenewals.isEmpty {
                emptyCard("Nothing renews in the next 30 days.", icon: .checkCircle)
            } else {
                RenewaCard {
                    Chart(upcomingRenewals) { subscription in
                        BarMark(
                            x: .value("Renewal", subscription.nextRenewalDate, unit: .day),
                            y: .value("Subscription", subscription.name)
                        )
                        .foregroundStyle(subscription.category.color)
                        .annotation(position: .trailing) {
                            Text(subscription.price.currencyText(code: subscription.currency))
                                .font(.renewa(11, weight: .semibold))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: max(150, CGFloat(upcomingRenewals.count) * 46))
                    .accessibilityLabel("Upcoming subscription renewal timeline")
                }
            }
        }
        .renewaEntrance(appeared, delay: 0.24)
    }

    private func emptyCard(_ message: String, icon: HeroIconName) -> some View {
        RenewaCard {
            HStack(alignment: .top, spacing: 12) {
                HeroIcon(icon, size: 24).foregroundStyle(RenewaTheme.muted)
                Text(message).font(.renewa(14)).foregroundStyle(RenewaTheme.muted)
            }
        }
    }
}

private struct TrendPoint: Identifiable {
    let date: Date
    let value: Decimal
    var id: Date { date }
}

private extension Decimal {
    var asDouble: Double { NSDecimalNumber(decimal: self).doubleValue }
}
