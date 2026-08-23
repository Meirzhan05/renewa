import Charts
import SwiftUI

struct InsightsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selectedMonth: Int?
    @State private var expandedCategory: SubscriptionCategory?
    @State private var activeFinding: InsightCard?

    let onAddSubscription: () -> Void
    let onScanInbox: () -> Void

    // MARK: - Derived data

    private var monthlyData: [MonthData] {
        let grouped = Dictionary(grouping: store.spendingSnapshots, by: \.periodStart)
        let months: [MonthData] = grouped.keys.sorted().compactMap { period in
            guard let snapshots = grouped[period] else { return nil }
            var total: Decimal = 0
            var amounts: [SubscriptionCategory: Decimal] = [:]
            for snapshot in snapshots {
                guard let convertedTotal = store.convertedMonthlyCost(for: snapshot) else { continue }
                total += convertedTotal
                let rawSum = snapshot.categoryTotals.values.reduce(0, +)
                guard rawSum > 0 else { continue }
                for (key, raw) in snapshot.categoryTotals {
                    let category = SubscriptionCategory(rawValue: key) ?? .other
                    amounts[category, default: 0] += convertedTotal * (raw / rawSum)
                }
            }
            guard total > 0 else { return nil }
            return MonthData(
                periodStart: period,
                total: total,
                categories: categoryData(from: amounts, monthTotal: total)
            )
        }
        return Array(months.suffix(6))
    }

    private var currentCategories: [CategoryDatum] {
        var amounts: [SubscriptionCategory: Decimal] = [:]
        for subscription in store.activeSubscriptions {
            guard let amount = store.convertedMonthlyCost(for: subscription) else { continue }
            amounts[subscription.category, default: 0] += amount
        }
        return categoryData(from: amounts, monthTotal: amounts.values.reduce(0, +))
    }

    private func categoryData(
        from amounts: [SubscriptionCategory: Decimal],
        monthTotal: Decimal
    ) -> [CategoryDatum] {
        let ranked = amounts.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard let top = ranked.first?.value, top > 0 else { return [] }
        let totalDouble = monthTotal.asDouble
        let topDouble = top.asDouble
        return ranked.map { category, amount in
            CategoryDatum(
                category: category,
                amount: amount,
                share: totalDouble > 0 ? amount.asDouble / totalDouble : 0,
                widthFraction: topDouble > 0 ? amount.asDouble / topDouble : 0,
                items: items(for: category)
            )
        }
    }

    private func items(for category: SubscriptionCategory) -> [CategoryItem] {
        store.activeSubscriptions
            .filter { $0.category == category }
            .compactMap { subscription in
                guard let amount = store.convertedMonthlyCost(for: subscription) else { return nil }
                return CategoryItem(id: subscription.id, name: subscription.name, amount: amount)
            }
            .sorted { $0.amount > $1.amount }
    }

    private func selectedIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selectedMonth ?? (count - 1), 0), count - 1)
    }

    private var displayedCategories: [CategoryDatum] {
        let data = monthlyData
        guard !data.isEmpty else { return currentCategories }
        return data[selectedIndex(data.count)].categories
    }

    private var snapshotPeriodCount: Int {
        Set(store.spendingSnapshots.map(\.periodStart)).count
    }

    private var presentationState: InsightsPresentationState {
        #if DEBUG
            if let override = InsightsView.qaPresentationState { return override }
        #endif
        return InsightsPresentationState(
            hasLoadedInsightsData: store.hasLoadedInsightsData,
            isLoadingInsightReport: store.isLoadingInsightReport,
            subscriptionCount: store.subscriptions.count,
            snapshotPeriodCount: snapshotPeriodCount,
            hasInsightReport: store.insightReport != nil,
            hasInsightsError: store.insightsErrorMessage != nil,
            activeSubscriptionCount: store.activeSubscriptions.count,
            unavailableConversionCount: store.unavailableConversionCount,
            usableTrendPointCount: monthlyData.count
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch presentationState.evidence {
                case .unresolved:
                    RenewaDelayedSkeleton(accessibilityLabel: "Loading insights") {
                        InsightsLoadingSkeleton()
                    }
                    .padding(.top, 20)
                case .activation:
                    activationState.padding(.top, 20)
                case .failure:
                    serviceFailureState.padding(.top, 20)
                case .dashboard:
                    dashboardContent
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .sensoryFeedback(.selection, trigger: selectedMonth)
        .refreshable { await store.loadInsights(force: true) }
        .task { await store.loadInsights() }
        .onAppear { appeared = true }
        .sheet(item: $activeFinding) { card in
            let style = insightFindingStyle(for: card)
            FindingDetailView(
                card: card,
                icon: style.icon,
                tint: style.tint,
                linkedSubscriptions: linkedSubscriptions(for: card),
                currency: store.defaultCurrency
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(RenewaTheme.background)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Insights")
                .font(.renewa(26, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
            Spacer(minLength: 8)
            if presentationState.evidence == .dashboard {
                if store.isRefreshingInsights {
                    Text("Updating…")
                        .font(.renewa(12, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                        .transition(.opacity)
                        .accessibilityLabel("Updating insights")
                }
                periodChip
            }
        }
        .padding(.top, 10)
        .renewaEntrance(appeared, delay: 0.02)
    }

    private var periodChip: some View {
        Text(periodLabel)
            .font(.renewa(12.5, weight: .bold))
            .foregroundStyle(RenewaTheme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RenewaTheme.divider.opacity(0.45), in: Capsule())
            .accessibilityLabel("Showing \(periodLabel)")
    }

    private var periodLabel: String {
        let count = monthlyData.count
        return count <= 1 ? "This month" : "Last \(count) months"
    }

    // MARK: - Dashboard

    @ViewBuilder
    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasSummaryContent {
                summarySection.padding(.top, 18)
                sectionSeparator
            } else {
                Color.clear.frame(height: 18)
            }

            trendSection

            sectionSeparator
            categorySection

            if let report = store.insightReport, !report.cards.isEmpty {
                sectionSeparator
                findingsSection
            }

            if store.unavailableConversionCount > 0 {
                partialConversionNote
            }

            Text("Figures come from your saved subscriptions and receipts. Nothing is estimated.")
                .font(.renewa(12))
                .foregroundStyle(RenewaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
        }
    }

    private var hasSummaryContent: Bool {
        store.insightReport != nil || store.isLoadingInsightReport || store.insightsErrorMessage != nil
    }

    private var sectionSeparator: some View {
        Rectangle()
            .fill(RenewaTheme.divider)
            .frame(height: 1)
            .padding(.vertical, 22)
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if let report = store.insightReport {
            let summaryState = InsightsSummaryPresentationState(report: report)
            VStack(alignment: .leading, spacing: 12) {
                AnimatedSummaryText(text: report.summary, animate: !reduceMotion && appeared)
                HStack(spacing: 6) {
                    HeroIcon(
                        summaryState.isAIDegraded ? .lightBulb : .sparkles,
                        style: summaryState.isAIDegraded ? .outline : .solid,
                        size: 13
                    )
                    .foregroundStyle(RenewaTheme.muted)
                    Text(summaryFooter(summaryState))
                        .font(.renewa(11.5, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if summaryState.isAIDegraded {
                    Button {
                        Task { await store.loadInsights(force: true) }
                    } label: {
                        HStack(spacing: 6) {
                            HeroIcon(.arrowPath, size: 13)
                            Text("Try AI again")
                        }
                        .font(.renewa(12.5, weight: .semibold))
                        .foregroundStyle(RenewaTheme.ink)
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(store.isLoadingInsightReport || store.isRefreshingInsights)
                    .accessibilityHint("Requests a new AI analysis without removing this summary")
                }
            }
            .renewaEntrance(appeared, delay: 0.06)
        } else if store.isLoadingInsightReport {
            RenewaDelayedSkeleton(accessibilityLabel: "Reading your subscription patterns") {
                InsightSummarySkeleton()
            }
            .padding(.top, 4)
        } else if let message = store.insightsErrorMessage {
            stateCard(
                title: "Renewa’s read is unavailable",
                message: message,
                icon: .lightBulb,
                tint: RenewaTheme.sand
            )
            .padding(.top, 4)
        }
    }

    private func summaryFooter(_ state: InsightsSummaryPresentationState) -> String {
        "\(state.sourceLabel) · \(state.generatedAt.formatted(.relative(presentation: .named)))"
    }

    // MARK: - Trend

    @ViewBuilder
    private var trendSection: some View {
        let data = monthlyData
        if data.count >= 2 {
            let index = selectedIndex(data.count)
            let month = data[index]
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(monthTitle(month.periodStart))
                            .font(.renewa(14, weight: .bold))
                            .foregroundStyle(RenewaTheme.ink)
                        Text(month.total.currencyText(code: store.defaultCurrency))
                            .font(.system(size: 37, weight: .regular, design: .serif))
                            .foregroundStyle(RenewaTheme.ink)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    deltaLabel(for: data, index: index)
                        .padding(.bottom, 5)
                }
                SpendTrendChart(
                    data: data,
                    selectedIndex: index,
                    currency: store.defaultCurrency,
                    onSelect: { newIndex in
                        guard newIndex != selectedIndex(data.count) else { return }
                        withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                            selectedMonth = newIndex
                            expandedCategory = nil
                        }
                    }
                )
            }
            .renewaEntrance(appeared, delay: 0.1)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Monthly spending trend")
        } else {
            trendFallback.renewaEntrance(appeared, delay: 0.1)
        }
    }

    @ViewBuilder
    private var trendFallback: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.activeSubscriptions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This month")
                        .font(.renewa(14, weight: .bold))
                        .foregroundStyle(RenewaTheme.ink)
                    Text(store.monthlySpend.currencyText(code: store.defaultCurrency))
                        .font(.system(size: 37, weight: .regular, design: .serif))
                        .foregroundStyle(RenewaTheme.ink)
                }
            }
            switch presentationState.trend {
            case .conversionUnavailable(let periodCount):
                stateCard(
                    title: "Trend unavailable",
                    message:
                        "We have history across \(periodCount) monthly periods, but their currencies couldn’t be converted to \(store.defaultCurrency). Try refreshing rates.",
                    icon: .exclamationTriangle,
                    tint: RenewaTheme.coral
                )
            default:
                stateCard(
                    title: snapshotPeriodCount == 1 ? "One month captured" : "History is building",
                    message: snapshotPeriodCount == 1
                        ? "Your trend will appear after the next monthly snapshot. We never estimate missing history."
                        : "Your trend will appear after Renewa records two monthly snapshots. We never estimate missing history.",
                    icon: .chartBar,
                    tint: RenewaTheme.sage
                )
            }
        }
    }

    @ViewBuilder
    private func deltaLabel(for data: [MonthData], index: Int) -> some View {
        if index == 0 {
            Text("first month tracked")
                .font(.renewa(12.5, weight: .semibold))
                .foregroundStyle(RenewaTheme.muted)
        } else {
            let diff = data[index].total - data[index - 1].total
            let tone: Color = diff > 0 ? RenewaTheme.coral : (diff < 0 ? RenewaTheme.sage : RenewaTheme.muted)
            let sign = diff >= 0 ? "+" : "−"
            Text("\(sign)\(abs(diff).currencyText(code: store.defaultCurrency)) from \(shortMonth(data[index - 1].periodStart))")
                .font(.renewa(12.5, weight: .semibold))
                .foregroundStyle(tone)
                .contentTransition(.opacity)
        }
    }

    // MARK: - Categories

    @ViewBuilder
    private var categorySection: some View {
        let categories = displayedCategories
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where it goes")
                    .font(.renewa(15, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Spacer()
                Text(categoryScopeLabel)
                    .font(.renewa(12, weight: .semibold))
                    .foregroundStyle(RenewaTheme.muted)
            }

            if categories.isEmpty {
                if store.activeSubscriptions.isEmpty {
                    stateCard(
                        title: "No current category spending",
                        message: "There are no active subscriptions to group. Any saved history remains available above.",
                        icon: .checkCircle,
                        tint: RenewaTheme.sage
                    )
                } else {
                    stateCard(
                        title: "Category mix unavailable",
                        message: "Your active subscriptions couldn’t be converted to \(store.defaultCurrency). Try refreshing rates.",
                        icon: .exclamationTriangle,
                        tint: RenewaTheme.coral
                    )
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(categories) { datum in
                        CategoryRow(
                            datum: datum,
                            currency: store.defaultCurrency,
                            isExpanded: expandedCategory == datum.category,
                            onTap: { toggleCategory(datum.category) }
                        )
                    }
                }
            }
        }
        .renewaEntrance(appeared, delay: 0.16)
    }

    private var categoryScopeLabel: String {
        let data = monthlyData
        guard !data.isEmpty else { return "This month" }
        return monthTitle(data[selectedIndex(data.count)].periodStart)
    }

    private func toggleCategory(_ category: SubscriptionCategory) {
        withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
            expandedCategory = expandedCategory == category ? nil : category
        }
    }

    // MARK: - Findings

    @ViewBuilder
    private var findingsSection: some View {
        if let report = store.insightReport, !report.cards.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Worth a look")
                    .font(.renewa(15, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                VStack(spacing: 16) {
                    ForEach(report.cards) { card in
                        FindingRow(card: card) { activeFinding = card }
                    }
                }
            }
            .renewaEntrance(appeared, delay: 0.22)
        }
    }

    private func linkedSubscriptions(for card: InsightCard) -> [Subscription] {
        card.subscriptionIDs.compactMap { identifier in
            store.subscriptions.first { $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame }
        }
    }

    private var partialConversionNote: some View {
        HStack(alignment: .top, spacing: 8) {
            HeroIcon(.exclamationTriangle, size: 14)
                .foregroundStyle(RenewaTheme.coral)
            Text(conversionMessage(excludedCount: store.unavailableConversionCount, isPartial: true))
                .font(.renewa(11.5, weight: .medium))
                .foregroundStyle(RenewaTheme.coral)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 22)
    }

    // MARK: - Shared states

    private var activationState: some View {
        RenewaCard {
            VStack(spacing: 22) {
                InsightsActivationGraphic()

                VStack(spacing: 8) {
                    Text("Your first insight starts with one subscription")
                        .font(.renewa(23, weight: .bold))
                        .foregroundStyle(RenewaTheme.ink)
                        .multilineTextAlignment(.center)
                    Text("Add what you pay for, or let Renewa discover subscriptions from your inbox.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 11) {
                    Button(action: onAddSubscription) {
                        HStack(spacing: 9) {
                            HeroIcon(.plus, style: .solid, size: 19)
                            Text("Add subscription")
                        }
                        .font(.renewa(16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 54)
                        .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Opens the manual subscription form")

                    Button(action: onScanInbox) {
                        HStack(spacing: 9) {
                            HeroIcon(.envelope, size: 20)
                            Text("Scan my inbox")
                        }
                        .font(.renewa(16, weight: .semibold))
                        .foregroundStyle(RenewaTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 52)
                        .background(
                            RenewaTheme.background.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Opens Inbox intelligence")
                }

                Divider()
                    .overlay(RenewaTheme.divider)

                HStack(alignment: .top, spacing: 8) {
                    activationBenefit(icon: .chartBar, title: "Spending mix", tint: RenewaTheme.sage)
                    activationBenefit(icon: .calendar, title: "Renewals", tint: RenewaTheme.coral)
                    activationBenefit(icon: .sparkles, title: "Trends", tint: RenewaTheme.sand)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .renewaEntrance(appeared, delay: 0.07)
    }

    private func activationBenefit(icon: HeroIconName, title: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            HeroIcon(icon, style: icon == .sparkles ? .solid : .outline, size: 19)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.renewa(12, weight: .semibold))
                .foregroundStyle(RenewaTheme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var serviceFailureState: some View {
        RenewaCard {
            VStack(spacing: 14) {
                HeroIcon(.exclamationTriangle, size: 34)
                    .foregroundStyle(RenewaTheme.coral)
                Text("Insights couldn’t load")
                    .font(.renewa(21, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(store.insightsErrorMessage ?? "Your insights are temporarily unavailable.")
                    .font(.renewa(15))
                    .foregroundStyle(RenewaTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await store.loadInsights(force: true) }
                } label: {
                    Text("Try again")
                        .font(.renewa(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(store.isLoadingInsights || store.isLoadingInsightReport || store.isRefreshingInsights)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .renewaEntrance(appeared, delay: 0.07)
    }

    private func stateCard(
        title: String,
        message: String,
        icon: HeroIconName,
        tint: Color
    ) -> some View {
        RenewaCard {
            HStack(alignment: .top, spacing: 12) {
                HeroIcon(icon, size: 23)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.renewa(15, weight: .bold))
                        .foregroundStyle(RenewaTheme.ink)
                    Text(message)
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func conversionMessage(excludedCount: Int, isPartial: Bool) -> String {
        let noun = excludedCount == 1 ? "subscription" : "subscriptions"
        if isPartial {
            return "Excludes \(excludedCount) \(noun) that couldn’t be converted to \(store.defaultCurrency)."
        }
        return "\(excludedCount) \(noun) couldn’t be converted to \(store.defaultCurrency). Try refreshing rates."
    }

    // MARK: - Formatting

    private func monthTitle(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.wide))
    }

    private func shortMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.abbreviated))
    }

    #if DEBUG
        private static var qaPresentationState: InsightsPresentationState? {
            switch ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] {
            case "insights-empty":
                return InsightsPresentationState(
                    hasLoadedInsightsData: true, isLoadingInsightReport: false,
                    subscriptionCount: 0, snapshotPeriodCount: 0, hasInsightReport: false,
                    hasInsightsError: false, activeSubscriptionCount: 0,
                    unavailableConversionCount: 0, usableTrendPointCount: 0
                )
            case "insights-failure":
                return InsightsPresentationState(
                    hasLoadedInsightsData: true, isLoadingInsightReport: false,
                    subscriptionCount: 0, snapshotPeriodCount: 0, hasInsightReport: false,
                    hasInsightsError: true, activeSubscriptionCount: 0,
                    unavailableConversionCount: 0, usableTrendPointCount: 0
                )
            case "insights-inactive":
                return InsightsPresentationState(
                    hasLoadedInsightsData: true, isLoadingInsightReport: false,
                    subscriptionCount: 1, snapshotPeriodCount: 0, hasInsightReport: false,
                    hasInsightsError: false, activeSubscriptionCount: 0,
                    unavailableConversionCount: 0, usableTrendPointCount: 0
                )
            default:
                return nil
            }
        }
    #endif
}

// MARK: - Finding styling

private func insightFindingStyle(for card: InsightCard) -> (icon: HeroIconName, tint: Color) {
    let text = (card.title + " " + card.body).lowercased()
    let savings = ["save", "cancel", "duplicate", "overlap", "lower", "cheaper", "unused", "downgrade"]
    let attention = ["trial", "increase", "rise", "rose", "risen", "charge", "ends", "renew", "up ", "higher"]
    if savings.contains(where: text.contains) {
        return (.sparkles, RenewaTheme.sage)
    }
    if attention.contains(where: text.contains) {
        return (.exclamationTriangle, RenewaTheme.coral)
    }
    return (.lightBulb, RenewaTheme.sand)
}

// MARK: - Interactive trend chart

private struct SpendTrendChart: View {
    let data: [MonthData]
    let selectedIndex: Int
    let currency: String
    let onSelect: (Int) -> Void

    var body: some View {
        let values = data.map { $0.total.asDouble }
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let span = max(maxValue - minValue, 1)

        VStack(spacing: 6) {
            Chart {
                ForEach(Array(data.enumerated()), id: \.element.id) { index, month in
                    AreaMark(
                        x: .value("Month", Double(index)),
                        y: .value("Spend", month.total.asDouble)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [RenewaTheme.sage.opacity(0.18), RenewaTheme.sage.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Month", Double(index)),
                        y: .value("Spend", month.total.asDouble)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(RenewaTheme.sage)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                }

                ForEach(Array(data.enumerated()), id: \.element.id) { index, month in
                    if index != selectedIndex {
                        PointMark(
                            x: .value("Month", Double(index)),
                            y: .value("Spend", month.total.asDouble)
                        )
                        .foregroundStyle(RenewaTheme.sageLight)
                        .symbolSize(26)
                    }
                }

                RuleMark(x: .value("Month", Double(selectedIndex)))
                    .foregroundStyle(RenewaTheme.divider)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                PointMark(
                    x: .value("Month", Double(selectedIndex)),
                    y: .value("Spend", data[selectedIndex].total.asDouble)
                )
                .foregroundStyle(RenewaTheme.sage)
                .symbolSize(165)

                PointMark(
                    x: .value("Month", Double(selectedIndex)),
                    y: .value("Spend", data[selectedIndex].total.asDouble)
                )
                .foregroundStyle(RenewaTheme.background)
                .symbolSize(66)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: -0.5 ... (Double(data.count - 1) + 0.5))
            .chartYScale(domain: (minValue - span * 0.7) ... (maxValue + span * 0.35))
            .frame(height: 108)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in select(at: value.location.x, proxy: proxy, geometry: geometry) }
                        )
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(data.enumerated()), id: \.element.id) { index, month in
                    Text(shortMonth(month.periodStart))
                        .font(.renewa(12, weight: index == selectedIndex ? .bold : .semibold))
                        .foregroundStyle(index == selectedIndex ? RenewaTheme.ink : RenewaTheme.muted.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(index) }
                        .accessibilityLabel("\(fullMonth(month.periodStart)), \(month.total.currencyText(code: currency))")
                        .accessibilityAddTraits(index == selectedIndex ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }

    private func select(at x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        guard let raw = proxy.value(atX: x - origin.x, as: Double.self) else { return }
        let index = min(max(Int(raw.rounded()), 0), data.count - 1)
        onSelect(index)
    }

    private func shortMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.abbreviated))
    }

    private func fullMonth(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().month(.wide))
    }
}

// MARK: - Category row

private struct CategoryRow: View {
    let datum: CategoryDatum
    let currency: String
    let isExpanded: Bool
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(datum.category.title)
                    .font(.renewa(14, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                Spacer(minLength: 8)
                Text("\(Int((datum.share * 100).rounded()))%")
                    .font(.renewa(12, weight: .semibold))
                    .foregroundStyle(RenewaTheme.muted)
                Text(datum.amount.currencyText(code: currency))
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .foregroundStyle(RenewaTheme.ink)
                    .contentTransition(.numericText())
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(RenewaTheme.divider.opacity(0.5))
                    Capsule()
                        .fill(datum.category.color)
                        .frame(width: max(0, (grown ? datum.widthFraction : 0) * geometry.size.width))
                }
            }
            .frame(height: 7)

            if isExpanded && !datum.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(datum.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.name)
                                .font(.renewa(12.5))
                                .foregroundStyle(RenewaTheme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.amount.currencyText(code: currency))
                                .font(.system(size: 14, weight: .regular, design: .serif))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !datum.items.isEmpty { onTap() } }
        .onAppear {
            guard !grown else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.85).delay(0.15)) {
                grown = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(datum.category.title), \(datum.amount.currencyText(code: currency)), \(Int((datum.share * 100).rounded())) percent")
        .accessibilityHint(datum.items.isEmpty ? "" : (isExpanded ? "Collapse breakdown" : "Expand breakdown"))
    }
}

// MARK: - Finding row + detail

private struct FindingRow: View {
    let card: InsightCard
    let onTap: () -> Void

    var body: some View {
        let style = insightFindingStyle(for: card)
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 11) {
                HeroIcon(style.icon, style: style.icon == .sparkles ? .solid : .outline, size: 12)
                    .foregroundStyle(style.tint)
                    .frame(width: 20, height: 20)
                    .background(style.tint.opacity(0.16), in: Circle())
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.renewa(14, weight: .semibold))
                        .foregroundStyle(RenewaTheme.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.body)
                        .font(.renewa(12.5))
                        .foregroundStyle(RenewaTheme.muted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                HeroIcon(.chevronRight, size: 13)
                    .foregroundStyle(RenewaTheme.muted.opacity(0.55))
                    .padding(.top, 3)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityHint("Opens the full breakdown")
    }
}

private struct FindingDetailView: View {
    let card: InsightCard
    let icon: HeroIconName
    let tint: Color
    let linkedSubscriptions: [Subscription]
    let currency: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                HeroIcon(icon, style: icon == .sparkles ? .solid : .outline, size: 19)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(card.title)
                    .font(.renewa(17, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            if !linkedSubscriptions.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(linkedSubscriptions) { subscription in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(subscription.name)
                                .font(.renewa(12.5, weight: .medium))
                                .foregroundStyle(RenewaTheme.muted)
                            Spacer(minLength: 8)
                            Text(subscription.price.currencyText(code: subscription.currency))
                                .font(.system(size: 16, weight: .regular, design: .serif))
                                .foregroundStyle(RenewaTheme.ink)
                        }
                    }
                }
                .padding(.top, 18)

                Rectangle()
                    .fill(RenewaTheme.divider)
                    .frame(height: 1)
                    .padding(.vertical, 18)
            } else {
                Spacer().frame(height: 18)
            }

            Text(card.body)
                .font(.renewa(13))
                .foregroundStyle(RenewaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Text("Based on your saved subscriptions and billing activity.")
                .font(.renewa(11, weight: .medium))
                .foregroundStyle(RenewaTheme.muted.opacity(0.8))
                .padding(.top, 8)

            Button { dismiss() } label: {
                Text("Got it")
                    .font(.renewa(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
                    .background(RenewaTheme.sage, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Animated summary

private struct AnimatedSummaryText: View {
    let text: String
    let animate: Bool

    @State private var revealed = false

    private var tokens: [Token] {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .enumerated()
            .map { index, word in
                Token(
                    id: index,
                    text: String(word),
                    emphasis: word.contains(where: \.isNumber)
                )
            }
    }

    var body: some View {
        FlowLayout(lineSpacing: 6) {
            ForEach(tokens) { token in
                Text(token.text + " ")
                    .font(.system(size: 16.5, weight: token.emphasis ? .semibold : .regular, design: .serif))
                    .foregroundStyle(RenewaTheme.ink)
                    .opacity(revealed ? 1 : 0)
                    .blur(radius: revealed ? 0 : 4)
                    .animation(
                        animate ? .easeOut(duration: 0.4).delay(Double(min(token.id, 45)) * 0.02) : nil,
                        value: revealed
                    )
            }
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private struct Token: Identifiable {
        let id: Int
        let text: String
        let emphasis: Bool
    }
}

// MARK: - Flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: proposal.width ?? max(widest, 0), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Local models

private struct MonthData: Identifiable {
    let periodStart: Date
    let total: Decimal
    let categories: [CategoryDatum]
    var id: Date { periodStart }
}

private struct CategoryDatum: Identifiable {
    let category: SubscriptionCategory
    let amount: Decimal
    let share: Double
    let widthFraction: Double
    let items: [CategoryItem]
    var id: SubscriptionCategory { category }
}

private struct CategoryItem: Identifiable {
    let id: UUID
    let name: String
    let amount: Decimal
}

// MARK: - Supporting views

private struct InsightsActivationGraphic: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(RenewaTheme.sage.opacity(0.1))
                .frame(width: 130, height: 130)
            Circle()
                .stroke(RenewaTheme.sage.opacity(0.2), lineWidth: 1)
                .frame(width: 104, height: 104)

            HStack(alignment: .bottom, spacing: 7) {
                activationBar(height: 30, color: RenewaTheme.sand)
                activationBar(height: 49, color: RenewaTheme.sageLight)
                activationBar(height: 68, color: RenewaTheme.sage)
            }
            .frame(height: 76, alignment: .bottom)

            HeroIcon(.sparkles, style: .solid, size: 19)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RenewaTheme.coral, in: Circle())
                .overlay {
                    Circle().stroke(RenewaTheme.surface, lineWidth: 4)
                }
                .offset(x: 49, y: -43)
        }
        .frame(height: 142)
        .accessibilityHidden(true)
    }

    private func activationBar(height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color)
            .frame(width: 22, height: height)
    }
}

private struct InsightsLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RenewaCard {
                HStack(alignment: .top, spacing: 15) {
                    ZStack {
                        Circle()
                            .fill(RenewaTheme.sage.opacity(0.13))
                        HeroIcon(.chartBar, size: 25)
                            .foregroundStyle(RenewaTheme.sage)
                    }
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preparing your insights")
                            .font(.renewa(17, weight: .bold))
                        Text("Bringing together your subscriptions and spending history.")
                            .font(.renewa(13))
                            .foregroundStyle(RenewaTheme.muted)
                        HStack(spacing: 8) {
                            RenewaSkeleton(width: 74, height: 10, cornerRadius: 5)
                            RenewaSkeleton(width: 92, height: 10, cornerRadius: 5)
                            RenewaSkeleton(width: 61, height: 10, cornerRadius: 5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct InsightSummarySkeleton: View {
    var body: some View {
        RenewaCard {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    Circle()
                        .fill(RenewaTheme.sage.opacity(0.13))
                    HeroIcon(.sparkles, style: .solid, size: 20)
                        .foregroundStyle(RenewaTheme.sage)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Refreshing Renewa’s read")
                        .font(.renewa(16, weight: .bold))
                    Text("Updating your latest subscription patterns.")
                        .font(.renewa(13))
                        .foregroundStyle(RenewaTheme.muted)
                    HStack(spacing: 8) {
                        RenewaSkeleton(width: 72, height: 9, cornerRadius: 5)
                        RenewaSkeleton(width: 104, height: 9, cornerRadius: 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private extension Decimal {
    var asDouble: Double { NSDecimalNumber(decimal: self).doubleValue }
}
