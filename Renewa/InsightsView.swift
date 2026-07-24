import SwiftUI

struct InsightsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateBars = false
    @State private var appeared = false

    private var categoryTotals: [(SubscriptionCategory, Decimal)] {
        Dictionary(
            grouping: store.activeSubscriptions.filter { $0.currency == store.defaultCurrency },
            by: \.category
        )
            .map { category, values in
                (category, values.reduce(Decimal.zero) { $0 + $1.monthlyCost })
            }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Insights")
                    .font(.renewa(32, weight: .bold))
                    .padding(.top, 18)
                    .renewaEntrance(appeared, delay: 0.02)

                RenewaCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Annual commitment")
                            .font(.renewa(15, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                        Text(store.yearlySpend.currencyText(code: store.defaultCurrency))
                            .font(.system(size: 43, weight: .medium, design: .serif))
                            .contentTransition(.numericText())
                        Text("That’s \(store.monthlySpend.currencyText(code: store.defaultCurrency)) every month.")
                            .font(.renewa(15))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .renewaEntrance(appeared, delay: 0.08)

                if categoryTotals.isEmpty {
                    ContentUnavailableView(
                        "No spending insights yet",
                        systemImage: "chart.bar",
                        description: Text("Add an active \(store.defaultCurrency) subscription to see a breakdown.")
                    )
                    .foregroundStyle(RenewaTheme.muted)
                    .renewaEntrance(appeared, delay: 0.14)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Where it goes")
                            .font(.renewa(20, weight: .bold))

                        ForEach(Array(categoryTotals.enumerated()), id: \.offset) { index, item in
                            VStack(spacing: 8) {
                                HStack {
                                    Label {
                                        Text(item.0.title)
                                    } icon: {
                                        Circle().fill(item.0.color).frame(width: 10, height: 10)
                                    }
                                    .font(.renewa(15, weight: .medium))
                                    Spacer()
                                    Text(item.1.currencyText(code: store.defaultCurrency))
                                        .font(.renewa(15, weight: .semibold))
                                }
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(RenewaTheme.divider.opacity(0.45))
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(item.0.color)
                                                .frame(width: animateBars ? proxy.size.width * share(item.1) : 0)
                                                .animation(
                                                    reduceMotion
                                                        ? .easeOut(duration: 0.12)
                                                        : RenewaMotion.gentle.delay(Double(index) * 0.08),
                                                    value: animateBars
                                                )
                                        }
                                }
                                .frame(height: 9)
                            }
                            .renewaEntrance(appeared, delay: 0.16 + Double(index) * 0.06, distance: 10)
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.14)
                }

                RenewaCard {
                    HStack(spacing: 16) {
                        Image(systemName: "lightbulb.max.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(RenewaTheme.sand)
                            .symbolEffect(.bounce, value: appeared)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A useful nudge")
                                .font(.renewa(16, weight: .bold))
                            Text("Review yearly plans 30 days before renewal. That’s when switching leverage is highest.")
                                .font(.renewa(14))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                    }
                }
                .renewaEntrance(appeared, delay: 0.28)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .onAppear {
            appeared = true
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : RenewaMotion.gentle.delay(0.08)
            ) {
                animateBars = true
            }
        }
    }

    private func share(_ value: Decimal) -> CGFloat {
        guard store.monthlySpend > 0 else { return 0 }
        return CGFloat(NSDecimalNumber(decimal: value / store.monthlySpend).doubleValue)
    }
}
