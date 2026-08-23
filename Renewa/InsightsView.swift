import Charts
import SwiftUI

struct InsightsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    let onAddSubscription: () -> Void
    let onScanInbox: () -> Void

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

    private var snapshotPeriodCount: Int {
        Set(store.spendingSnapshots.map(\.periodStart)).count
    }

    private var presentationState: InsightsPresentationState {
        #if DEBUG
            if ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] == "insights-empty" {
                return InsightsPresentationState(
                    hasLoadedInsightsData: true,
                    isLoadingInsightReport: false,
                    subscriptionCount: 0,
                    snapshotPeriodCount: 0,
                    hasInsightReport: false,
                    hasInsightsError: false,
                    activeSubscriptionCount: 0,
                    unavailableConversionCount: 0,
                    usableTrendPointCount: 0
                )
            }
            if ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] == "insights-failure" {
                return InsightsPresentationState(
                    hasLoadedInsightsData: true,
                    isLoadingInsightReport: false,
                    subscriptionCount: 0,
                    snapshotPeriodCount: 0,
                    hasInsightReport: false,
                    hasInsightsError: true,
                    activeSubscriptionCount: 0,
                    unavailableConversionCount: 0,
                    usableTrendPointCount: 0
                )
            }
            if ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] == "insights-inactive" {
                return InsightsPresentationState(
                    hasLoadedInsightsData: true,
                    isLoadingInsightReport: false,
                    subscriptionCount: 1,
                    snapshotPeriodCount: 0,
                    hasInsightReport: false,
                    hasInsightsError: false,
                    activeSubscriptionCount: 0,
                    unavailableConversionCount: 0,
                    usableTrendPointCount: 0
                )
            }
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
            usableTrendPointCount: trendPoints.count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                switch presentationState.evidence {
                case .unresolved:
                    RenewaDelayedSkeleton(accessibilityLabel: "Loading insights") {
                        InsightsLoadingSkeleton()
                    }
                case .activation:
                    activationState
                case .failure:
                    serviceFailureState
                case .dashboard:
                    commitmentCard
                    aiSummary
                    trendSection
                    categorySection
                    renewalSection
                }
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
            if presentationState.evidence == .dashboard {
                if store.isRefreshingInsights {
                    Text("Updating…")
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                        .transition(.opacity)
                        .accessibilityLabel("Updating insights")
                }
                Button {
                    Task { await store.loadInsights(force: true) }
                } label: {
                    HeroIcon(.arrowPath, size: 20)
                        .foregroundStyle(RenewaTheme.ink)
                        .frame(width: 40, height: 40)
                        .background(RenewaTheme.surface, in: Circle())
                }
                .buttonStyle(PressScaleStyle())
                .disabled(store.isLoadingInsights || store.isLoadingInsightReport || store.isRefreshingInsights)
                .accessibilityLabel("Refresh insights")
            }
        }
        .padding(.top, 18)
        .renewaEntrance(appeared, delay: 0.02)
    }

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
                    activationBenefit(
                        icon: .chartBar,
                        title: "Spending mix",
                        tint: RenewaTheme.sage
                    )
                    activationBenefit(
                        icon: .calendar,
                        title: "Renewals",
                        tint: RenewaTheme.coral
                    )
                    activationBenefit(
                        icon: .sparkles,
                        title: "Trends",
                        tint: RenewaTheme.sand
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .renewaEntrance(appeared, delay: 0.07)
    }

    private func activationBenefit(
        icon: HeroIconName,
        title: String,
        tint: Color
    ) -> some View {
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

    @ViewBuilder
    private var commitmentCard: some View {
        RenewaCard {
            VStack(alignment: .leading, spacing: 10) {
                switch presentationState.commitment {
                case .noActiveSubscriptions:
                    Label {
                        Text("No active commitments")
                    } icon: {
                        HeroIcon(.checkCircle, style: .solid, size: 22)
                    }
                    .font(.renewa(22, weight: .bold))
                    .foregroundStyle(RenewaTheme.sage)
                    Text("Your previous subscriptions and any available history remain below.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                case .unavailable(let excludedCount):
                    Text("Annual commitment")
                        .font(.renewa(15, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                    Text("Total unavailable")
                        .font(.renewa(30, weight: .bold))
                        .foregroundStyle(RenewaTheme.ink)
                    Text(conversionMessage(excludedCount: excludedCount, isPartial: false))
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                case .partial(let excludedCount):
                    Text("Known annual commitment")
                        .font(.renewa(15, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                    Text("≈ \(store.yearlySpend.currencyText(code: store.defaultCurrency))")
                        .font(.system(size: 43, weight: .medium, design: .serif))
                        .contentTransition(.numericText())
                    Text("That’s \(store.monthlySpend.currencyText(code: store.defaultCurrency)) every month from converted subscriptions.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                    Text(conversionMessage(excludedCount: excludedCount, isPartial: true))
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                case .complete:
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .renewaEntrance(appeared, delay: 0.07)
    }

    private func conversionMessage(excludedCount: Int, isPartial: Bool) -> String {
        let noun = excludedCount == 1 ? "subscription" : "subscriptions"
        if isPartial {
            return "Excludes \(excludedCount) \(noun) that couldn’t be converted to \(store.defaultCurrency)."
        }
        return "\(excludedCount) \(noun) couldn’t be converted to \(store.defaultCurrency). Try refreshing rates."
    }

    @ViewBuilder
    private var aiSummary: some View {
        if let report = store.insightReport {
            let summaryState = InsightsSummaryPresentationState(report: report)
            RenewaCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 9) {
                        HeroIcon(
                            summaryState.isAIDegraded ? .lightBulb : .sparkles,
                            style: summaryState.isAIDegraded ? .outline : .solid,
                            size: 21
                        )
                        .foregroundStyle(summaryState.isAIDegraded ? RenewaTheme.sand : RenewaTheme.sage)
                        Text(summaryState.title)
                            .font(.renewa(16, weight: .bold))
                        if store.isRefreshingInsights {
                            Text("Updating…")
                                .font(.renewa(12, weight: .semibold))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                    }
                    Text("\(summaryState.sourceLabel) · \(insightFreshness(summaryState.generatedAt))")
                        .font(.renewa(12, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
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
                    if let evidenceLabel = summaryState.evidenceLabel {
                        Text(evidenceLabel)
                            .font(.renewa(12, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                    if summaryState.isAIDegraded {
                        Divider().overlay(RenewaTheme.divider)
                        Text("AI is temporarily unavailable. This basic summary still uses your current subscription facts.")
                            .font(.renewa(13))
                            .foregroundStyle(RenewaTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await store.loadInsights(force: true) }
                        } label: {
                            HStack(spacing: 7) {
                                HeroIcon(.arrowPath, size: 16)
                                Text("Try AI again")
                            }
                            .font(.renewa(14, weight: .semibold))
                            .foregroundStyle(RenewaTheme.ink)
                            .frame(minHeight: 38)
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(store.isLoadingInsightReport || store.isRefreshingInsights)
                        .accessibilityHint("Requests a new AI analysis without removing this summary")
                    }
                }
            }
            .renewaEntrance(appeared, delay: 0.12)
        } else if store.isLoadingInsightReport {
            RenewaDelayedSkeleton(accessibilityLabel: "Reading your subscription patterns") {
                InsightSummarySkeleton()
            }
        } else if let message = store.insightsErrorMessage {
            stateCard(
                title: "Renewa’s read is unavailable",
                message: message,
                icon: .lightBulb,
                tint: RenewaTheme.sand
            )
        }
    }

    private func insightFreshness(_ date: Date) -> String {
        "Updated \(date.formatted(.relative(presentation: .named)))"
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Monthly commitment")
                .font(.renewa(20, weight: .bold))
            switch presentationState.trend {
            case .available:
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
                        Text("Showing persisted monthly commitments in \(store.defaultCurrency).")
                            .font(.renewa(12))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Monthly commitment trend with \(trendPoints.count) monthly data points in \(store.defaultCurrency)")
            case .conversionUnavailable(let periodCount):
                stateCard(
                    title: "Trend unavailable",
                    message:
                        "We have history across \(periodCount) monthly periods, but their currencies couldn’t be converted to \(store.defaultCurrency). Try refreshing rates.",
                    icon: .exclamationTriangle,
                    tint: RenewaTheme.coral
                )
            case .building(let periodCount):
                stateCard(
                    title: periodCount == 1 ? "One month captured" : "History is building",
                    message: periodCount == 1
                        ? "Your trend will appear after the next monthly snapshot. We never estimate missing history."
                        : "Your trend will appear after Renewa records two monthly snapshots. We never estimate missing history.",
                    icon: .chartBar,
                    tint: RenewaTheme.sage
                )
            }
        }
        .renewaEntrance(appeared, delay: 0.16)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Where it goes")
                .font(.renewa(20, weight: .bold))
            if store.activeSubscriptions.isEmpty {
                stateCard(
                    title: "No current category spending",
                    message: "There are no active subscriptions to group. Any saved history remains available above.",
                    icon: .checkCircle,
                    tint: RenewaTheme.sage
                )
            } else if categoryTotals.isEmpty {
                stateCard(
                    title: "Category mix unavailable",
                    message: "Your active subscriptions couldn’t be converted to \(store.defaultCurrency). Try refreshing rates.",
                    icon: .exclamationTriangle,
                    tint: RenewaTheme.coral
                )
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
                        if store.unavailableConversionCount > 0 {
                            Label {
                                Text(
                                    conversionMessage(
                                        excludedCount: store.unavailableConversionCount,
                                        isPartial: true
                                    )
                                )
                            } icon: {
                                HeroIcon(.exclamationTriangle, size: 17)
                            }
                            .font(.renewa(12, weight: .medium))
                            .foregroundStyle(RenewaTheme.coral)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            if store.activeSubscriptions.isEmpty {
                stateCard(
                    title: "No active renewals",
                    message: "There are no current subscription payments to schedule.",
                    icon: .checkCircle,
                    tint: RenewaTheme.sage
                )
            } else if upcomingRenewals.isEmpty {
                stateCard(
                    title: "You’re clear for 30 days",
                    message: "No active subscription payments are scheduled in the next 30 days.",
                    icon: .checkCircle,
                    tint: RenewaTheme.sage
                )
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
}

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

private struct TrendPoint: Identifiable {
    let date: Date
    let value: Decimal
    var id: Date { date }
}

private extension Decimal {
    var asDouble: Double { NSDecimalNumber(decimal: self).doubleValue }
}
