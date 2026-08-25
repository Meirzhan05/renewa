import SwiftUI

struct InsightsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var selectedMonthIndex: Int?
    @State private var expandedCategory: SubscriptionCategory?
    @State private var selectedFinding: InsightsSummaryPresentationState.Finding?

    let onAddSubscription: () -> Void
    let onScanInbox: () -> Void

    // MARK: - Store-derived state

    /// Snapshots arrive one row per currency per month, so a month is only usable once every one
    /// of its rows converts into the display currency.
    private var historyInputs: [SpendHistoryPresentationState.Input] {
        Dictionary(grouping: store.spendingSnapshots, by: \.periodStart)
            .compactMap { period, rows -> SpendHistoryPresentationState.Input? in
                let usable = rows.filter { store.convertedMonthlyCost(for: $0) != nil }
                guard !usable.isEmpty else { return nil }

                var categories: [SubscriptionCategory: Decimal] = [:]
                for row in usable {
                    for (key, amount) in row.categoryTotals {
                        guard let category = SubscriptionCategory(rawValue: key),
                            let converted = store.convertedAmount(amount, from: row.currency)
                        else { continue }
                        categories[category, default: 0] += converted
                    }
                }

                return SpendHistoryPresentationState.Input(
                    periodStart: period,
                    total: usable.compactMap { store.convertedMonthlyCost(for: $0) }.reduce(Decimal.zero, +),
                    categoryTotals: categories
                )
            }
            .sorted { $0.periodStart < $1.periodStart }
    }

    private var currentLineItems: [SubscriptionCategory: [SpendHistoryPresentationState.LineItem]] {
        Dictionary(grouping: store.activeSubscriptions, by: \.category)
            .mapValues { subscriptions in
                subscriptions
                    .sorted { $0.monthlyCost > $1.monthlyCost }
                    .map { subscription in
                        let converted = store.convertedMonthlyCost(for: subscription)
                        return SpendHistoryPresentationState.LineItem(
                            id: subscription.id,
                            name: subscription.name,
                            priceText: (converted ?? subscription.monthlyCost).currencyText(
                                code: converted == nil ? subscription.currency : store.defaultCurrency
                            )
                        )
                    }
            }
    }

    private var history: SpendHistoryPresentationState {
        SpendHistoryPresentationState(
            inputs: historyInputs,
            selectedIndex: selectedMonthIndex,
            displayCurrency: store.defaultCurrency,
            currentLineItems: currentLineItems
        )
    }

    /// What is committed right now. Stands in for the category breakdown before Renewa has
    /// recorded its first monthly snapshot.
    private var liveHistory: SpendHistoryPresentationState {
        var totals: [SubscriptionCategory: Decimal] = [:]
        for subscription in store.activeSubscriptions {
            guard let cost = store.convertedMonthlyCost(for: subscription) else { continue }
            totals[subscription.category, default: 0] += cost
        }

        return SpendHistoryPresentationState(
            inputs: [
                SpendHistoryPresentationState.Input(
                    periodStart: .now,
                    total: store.monthlySpend,
                    categoryTotals: totals
                )
            ],
            displayCurrency: store.defaultCurrency,
            currentLineItems: currentLineItems
        )
    }

    private var categoryRows: [SpendHistoryPresentationState.CategoryRow] {
        history.isEmpty ? liveHistory.categories : history.categories
    }

    private var summaryState: InsightsSummaryPresentationState? {
        store.insightReport.map { report in
            InsightsSummaryPresentationState(
                report: report,
                subscriptions: store.subscriptions.map { subscription in
                    InsightsSummaryPresentationState.SubscriptionFacts(
                        id: subscription.id,
                        name: subscription.name,
                        cadenceLabel: subscription.billingCycle.title.lowercased(),
                        monthlyCost: store.convertedMonthlyCost(for: subscription)
                    )
                },
                displayCurrency: store.defaultCurrency
            )
        }
    }

    private var upcomingRenewals: [Subscription] {
        let limit = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        return store.activeSubscriptions
            .filter { $0.nextRenewalDate >= .now.startOfDay && $0.nextRenewalDate <= limit }
            .sorted { $0.nextRenewalDate < $1.nextRenewalDate }
    }

    private var snapshotPeriodCount: Int {
        Set(store.spendingSnapshots.map(\.periodStart)).count
    }

    private var presentationState: InsightsPresentationState {
        #if DEBUG
            if let stubbed = Self.qaPresentationState { return stubbed }
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
            usableTrendPointCount: historyInputs.count
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
                    .padding(.top, 24)
                case .activation:
                    activationState.padding(.top, 24)
                case .failure:
                    serviceFailureState.padding(.top, 24)
                case .dashboard:
                    dashboard
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .task { await store.loadInsights() }
        .onAppear { appeared = true }
        .sheet(item: $selectedFinding) { finding in
            FindingDetailSheet(finding: finding, footnote: summaryState?.evidenceLabel)
        }
    }

    @ViewBuilder
    private var dashboard: some View {
        summarySection
        rule
        trendSection
        rule
        categorySection
        rule
        renewalSection
        if let summaryState, !summaryState.findings.isEmpty {
            rule
            findingsSection(summaryState)
        }

        Text("Totals come from the monthly snapshots Renewa has recorded. Nothing is estimated.")
            .font(.renewa(13))
            .foregroundStyle(RenewaTheme.mutedSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 34)
    }

    private var rule: some View {
        Rectangle()
            .fill(RenewaTheme.divider.opacity(0.7))
            .frame(height: 1)
            .padding(.vertical, 26)
            .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Insights")
                .font(.renewa(28, weight: .bold))

            Spacer(minLength: 8)

            if presentationState.evidence == .dashboard {
                if store.isRefreshingInsights {
                    Text("Updating…")
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                        .transition(.opacity)
                        .accessibilityLabel("Updating insights")
                } else if !history.isEmpty {
                    Text(history.windowLabel)
                        .font(.renewa(13.5, weight: .bold))
                        .foregroundStyle(RenewaTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RenewaTheme.track, in: Capsule())
                        .accessibilityLabel("Showing \(history.windowLabel.lowercased())")
                }

                Button {
                    Task { await store.loadInsights(force: true) }
                } label: {
                    HeroIcon(.arrowPath, size: 19)
                        .foregroundStyle(RenewaTheme.ink)
                        .frame(width: 38, height: 38)
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

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if let summaryState {
            VStack(alignment: .leading, spacing: 10) {
                if summaryState.paragraphs.isEmpty {
                    Text(store.insightReport?.summary ?? "")
                        .font(.system(size: 20, design: .serif))
                        .foregroundStyle(RenewaTheme.ink)
                } else {
                    ForEach(summaryState.paragraphs) { paragraph in
                        SummaryProse(
                            paragraph: paragraph,
                            wordOffset: wordOffset(before: paragraph, in: summaryState),
                            isVisible: appeared
                        )
                    }
                }

                summaryFooter(summaryState)

                if summaryState.isAIDegraded {
                    degradedNotice
                }
            }
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if store.isLoadingInsightReport {
            RenewaDelayedSkeleton(accessibilityLabel: "Reading your subscription patterns") {
                InsightSummarySkeleton()
            }
            .padding(.top, 22)
        } else if let message = store.insightsErrorMessage {
            stateCard(
                title: "Renewa’s read is unavailable",
                message: message,
                icon: .lightBulb,
                tint: RenewaTheme.sand
            )
            .padding(.top, 22)
        }
    }

    private func summaryFooter(_ state: InsightsSummaryPresentationState) -> some View {
        HStack(alignment: .top, spacing: 7) {
            HeroIcon(state.isAIDegraded ? .lightBulb : .sparkles, style: .solid, size: 14)
                .foregroundStyle(RenewaTheme.mutedSoft)
                .padding(.top, 1)
            Text(footerLine(state))
                .font(.renewa(13, weight: .medium))
                .foregroundStyle(RenewaTheme.mutedSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    private func footerLine(_ state: InsightsSummaryPresentationState) -> String {
        let freshness = "updated \(state.generatedAt.formatted(.relative(presentation: .named)))"
        guard let evidence = state.evidenceLabel else {
            return "\(state.sourceLabel) · \(freshness)"
        }
        return "\(evidence) · \(freshness)"
    }

    private var degradedNotice: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("AI is temporarily unavailable. This basic summary still uses your current subscription facts.")
                .font(.renewa(13))
                .foregroundStyle(RenewaTheme.mutedBody)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await store.loadInsights(force: true) }
            } label: {
                HStack(spacing: 7) {
                    HeroIcon(.arrowPath, size: 15)
                    Text("Try AI again")
                }
                .font(.renewa(14, weight: .semibold))
                .foregroundStyle(RenewaTheme.ink)
            }
            .buttonStyle(PressScaleStyle())
            .disabled(store.isLoadingInsightReport || store.isRefreshingInsights)
            .accessibilityHint("Requests a new AI analysis without removing this summary")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 6)
    }

    /// How many words precede this paragraph, so the reveal keeps running across the whole summary.
    private func wordOffset(
        before paragraph: InsightsSummaryPresentationState.Paragraph,
        in state: InsightsSummaryPresentationState
    ) -> Int {
        state.paragraphs
            .prefix { $0.id != paragraph.id }
            .reduce(0) { $0 + $1.words.count }
    }

    // MARK: - Trend

    @ViewBuilder
    private var trendSection: some View {
        if history.isEmpty {
            trendPlaceholder
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(history.selectedTitle)
                            .font(.renewa(16, weight: .bold))
                            .contentTransition(.opacity)
                        Text(history.selectedTotalText)
                            .font(.system(size: 42, weight: .regular, design: .serif))
                            .foregroundStyle(RenewaTheme.ink)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 8)
                    Text(history.deltaLabel)
                        .font(.renewa(13.5, weight: .semibold))
                        .foregroundStyle(tone(for: history.deltaDirection))
                        .padding(.bottom, 7)
                }

                if history.hasTrendLine {
                    SpendTrendChart(
                        months: history.months,
                        selectedIndex: history.selectedIndex,
                        isVisible: appeared,
                        onSelect: select(month:)
                    )

                    HStack(spacing: 0) {
                        ForEach(Array(history.months.enumerated()), id: \.element.id) { index, month in
                            Button {
                                select(month: index)
                            } label: {
                                Text(month.shortLabel)
                                    .font(.renewa(13, weight: index == history.selectedIndex ? .bold : .semibold))
                                    .foregroundStyle(
                                        index == history.selectedIndex ? RenewaTheme.ink : RenewaTheme.mutedSoft
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(month.fullLabel), \(month.totalText)")
                            .accessibilityAddTraits(index == history.selectedIndex ? .isSelected : [])
                        }
                    }
                } else {
                    Text("The trend line appears once Renewa has recorded a second month.")
                        .font(.renewa(13))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .renewaEntrance(appeared, delay: 0.12)
        }
    }

    @ViewBuilder
    private var trendPlaceholder: some View {
        switch presentationState.trend {
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
        case .available:
            // Unreachable: a usable trend point is exactly what makes `history` non-empty.
            EmptyView()
        }
    }

    private func select(month index: Int) {
        guard index != history.selectedIndex else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.quick) {
            selectedMonthIndex = index
            expandedCategory = nil
        }
    }

    private func tone(for direction: SpendHistoryPresentationState.Direction) -> Color {
        switch direction {
        case .up: RenewaTheme.clay
        case .down: RenewaTheme.positive
        case .flat, .unknown: RenewaTheme.mutedSoft
        }
    }

    // MARK: - Where it goes

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where it goes")
                    .font(.renewa(16, weight: .bold))
                Spacer()
                Text(history.isEmpty ? "Tracked today" : history.selectedTitle)
                    .font(.renewa(13, weight: .semibold))
                    .foregroundStyle(RenewaTheme.mutedSoft)
            }

            if store.activeSubscriptions.isEmpty && categoryRows.isEmpty {
                emptyLine("There are no active subscriptions to group. Any recorded history stays above.")
            } else if categoryRows.isEmpty {
                emptyLine(
                    "Your active subscriptions couldn’t be converted to \(store.defaultCurrency). Try refreshing rates."
                )
            } else {
                VStack(spacing: 18) {
                    ForEach(categoryRows) { row in
                        categoryRow(row)
                    }
                }

                if case .partial(let excludedCount) = presentationState.commitment {
                    conversionNote(excludedCount: excludedCount)
                } else if case .unavailable(let excludedCount) = presentationState.commitment {
                    conversionNote(excludedCount: excludedCount)
                }
            }
        }
        .renewaEntrance(appeared, delay: 0.16)
    }

    private func categoryRow(_ row: SpendHistoryPresentationState.CategoryRow) -> some View {
        let isOpen = expandedCategory == row.category

        return Button {
            guard row.isExpandable else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.quick) {
                expandedCategory = isOpen ? nil : row.category
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.category.title)
                        .font(.renewa(15, weight: .semibold))
                        .foregroundStyle(RenewaTheme.ink)
                    Spacer(minLength: 8)
                    Text(row.shareLabel)
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                    Text(row.amountText)
                        .font(.system(size: 19, weight: .regular, design: .serif))
                        .foregroundStyle(RenewaTheme.ink)
                        .contentTransition(.numericText())
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(RenewaTheme.track)
                        Capsule()
                            .fill(row.category.color)
                            .frame(width: max(proxy.size.width * row.barFraction, 10))
                    }
                }
                .frame(height: 9)
                .padding(.top, 9)

                if isOpen {
                    VStack(alignment: .leading, spacing: 9) {
                        if let changeLabel = row.changeLabel {
                            Text(changeLabel)
                                .font(.renewa(13, weight: .semibold))
                                .foregroundStyle(tone(for: row.changeDirection))
                        }
                        ForEach(row.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(item.name)
                                    .font(.renewa(14))
                                    .foregroundStyle(RenewaTheme.mutedBody)
                                Spacer(minLength: 8)
                                Text(item.priceText)
                                    .font(.system(size: 16, weight: .regular, design: .serif))
                                    .foregroundStyle(RenewaTheme.muted)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint(row.isExpandable ? "Opens what sits in this category" : "")
    }

    private func conversionNote(excludedCount: Int) -> some View {
        let noun = excludedCount == 1 ? "subscription" : "subscriptions"
        return Label {
            Text("Excludes \(excludedCount) \(noun) that couldn’t be converted to \(store.defaultCurrency).")
        } icon: {
            HeroIcon(.exclamationTriangle, size: 15)
        }
        .font(.renewa(13, weight: .medium))
        .foregroundStyle(RenewaTheme.coral)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Next 30 days

    private var renewalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Next 30 days")
                    .font(.renewa(16, weight: .bold))
                Spacer()
                if let upcomingTotalText {
                    Text(upcomingTotalText)
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                }
            }

            if upcomingRenewals.isEmpty {
                emptyLine(
                    store.activeSubscriptions.isEmpty
                        ? "There are no current subscription payments to schedule."
                        : "No active subscription payments are scheduled in the next 30 days."
                )
            } else {
                VStack(spacing: 14) {
                    ForEach(upcomingRenewals) { subscription in
                        renewalRow(subscription)
                    }
                }
            }
        }
        .renewaEntrance(appeared, delay: 0.2)
    }

    /// Only quotable when every renewal converts — a partial sum would understate what is due.
    private var upcomingTotalText: String? {
        let converted = upcomingRenewals.compactMap {
            store.convertedAmount($0.price, from: $0.currency)
        }
        guard !converted.isEmpty, converted.count == upcomingRenewals.count else { return nil }
        return "\(converted.reduce(Decimal.zero, +).currencyText(code: store.defaultCurrency)) due"
    }

    private func renewalRow(_ subscription: Subscription) -> some View {
        let days =
            Calendar.current
            .dateComponents([.day], from: .now.startOfDay, to: subscription.nextRenewalDate.startOfDay)
            .day ?? 0

        return HStack(alignment: .center, spacing: 12) {
            Capsule()
                .fill(subscription.category.color)
                .frame(width: 3, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.renewa(15, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                    .lineLimit(1)
                Text(renewalTiming(days: days, date: subscription.nextRenewalDate))
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(days <= 7 ? RenewaTheme.clay : RenewaTheme.mutedSoft)
            }

            Spacer(minLength: 8)

            Text(subscription.price.currencyText(code: subscription.currency))
                .font(.system(size: 17, weight: .regular, design: .serif))
                .foregroundStyle(RenewaTheme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func renewalTiming(days: Int, date: Date) -> String {
        let dateLabel = date.formatted(.dateTime.month(.abbreviated).day())
        return switch days {
        case 0: "Renews today"
        case 1: "Renews tomorrow"
        default: "\(dateLabel) · in \(days) days"
        }
    }

    // MARK: - Worth a look

    private func findingsSection(_ state: InsightsSummaryPresentationState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Worth a look")
                    .font(.renewa(16, weight: .bold))
                Spacer()
                if let findingsLabel = state.findingsLabel {
                    Text(findingsLabel)
                        .font(.renewa(13, weight: .bold))
                        .foregroundStyle(RenewaTheme.positive)
                }
            }

            VStack(spacing: 18) {
                ForEach(state.findings) { finding in
                    Button {
                        selectedFinding = finding
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            HeroIcon(.sparkles, style: .solid, size: 12)
                                .foregroundStyle(RenewaTheme.sage)
                                .frame(width: 22, height: 22)
                                .background(RenewaTheme.sageTint, in: Circle())
                                .padding(.top, 1)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.title)
                                    .font(.renewa(15, weight: .semibold))
                                    .foregroundStyle(RenewaTheme.ink)
                                    .multilineTextAlignment(.leading)
                                Text(finding.meta)
                                    .font(.renewa(13.5, weight: .medium))
                                    .foregroundStyle(RenewaTheme.mutedBody)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 6)

                            HeroIcon(.chevronRight, size: 15)
                                .foregroundStyle(RenewaTheme.mutedSoft.opacity(0.8))
                                .padding(.top, 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Opens the detail behind this insight")
                }
            }
        }
        .renewaEntrance(appeared, delay: 0.24)
    }

    // MARK: - Shared pieces

    private func emptyLine(_ message: String) -> some View {
        Text(message)
            .font(.renewa(14))
            .foregroundStyle(RenewaTheme.mutedBody)
            .fixedSize(horizontal: false, vertical: true)
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

    #if DEBUG
        private static var qaPresentationState: InsightsPresentationState? {
            func stub(
                subscriptionCount: Int,
                hasInsightsError: Bool
            ) -> InsightsPresentationState {
                InsightsPresentationState(
                    hasLoadedInsightsData: true,
                    isLoadingInsightReport: false,
                    subscriptionCount: subscriptionCount,
                    snapshotPeriodCount: 0,
                    hasInsightReport: false,
                    hasInsightsError: hasInsightsError,
                    activeSubscriptionCount: 0,
                    unavailableConversionCount: 0,
                    usableTrendPointCount: 0
                )
            }

            return switch ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] {
            case "insights-empty": stub(subscriptionCount: 0, hasInsightsError: false)
            case "insights-failure": stub(subscriptionCount: 0, hasInsightsError: true)
            case "insights-inactive": stub(subscriptionCount: 1, hasInsightsError: false)
            default: nil
            }
        }
    #endif
}

// MARK: - Summary prose

/// One paragraph of the summary, revealed a word at a time the way the report is written.
private struct SummaryProse: View {
    let paragraph: InsightsSummaryPresentationState.Paragraph
    let wordOffset: Int
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Past this the reveal outlasts the reader's patience, so the tail lands together.
    private static let lastStaggeredWord = 44

    private var bodySize: CGFloat { paragraph.isLead ? 20 : 15.5 }
    private var figureSize: CGFloat { paragraph.isLead ? 20 : 17 }

    var body: some View {
        FlowLayout(
            spacing: paragraph.isLead ? 5.5 : 4.5,
            lineSpacing: paragraph.isLead ? 9 : 7,
            alignment: .firstTextBaseline
        ) {
            ForEach(paragraph.words) { word in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(word.fragments) { fragment in
                        Text(fragment.text)
                            .font(font(for: fragment))
                            .foregroundStyle(color(for: fragment))
                    }
                }
                .opacity(isVisible ? 1 : 0)
                .blur(radius: isVisible ? 0 : 4)
                .offset(y: isVisible ? 0 : 3)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.44).delay(delay(for: word)),
                    value: isVisible
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paragraph.plainText)
    }

    private func font(for fragment: InsightsSummaryPresentationState.Fragment) -> Font {
        if fragment.isFigure {
            return .system(size: figureSize, weight: paragraph.isLead ? .medium : .regular, design: .serif)
        }
        return paragraph.isLead
            ? .system(size: bodySize, weight: .regular, design: .serif)
            : .renewa(bodySize, weight: .medium)
    }

    private func color(for fragment: InsightsSummaryPresentationState.Fragment) -> Color {
        if paragraph.isLead { return RenewaTheme.ink }
        return fragment.isFigure ? RenewaTheme.ink : RenewaTheme.muted
    }

    private func delay(for word: InsightsSummaryPresentationState.Word) -> Double {
        let index = min(wordOffset + word.id, Self.lastStaggeredWord)
        return 0.16 + Double(index) * 0.028
    }
}

// MARK: - Trend chart

/// The recorded months as a scrubable line. Hand-drawn rather than charted so the selected month
/// can carry the dashed rule, the ring, and its own figure the way the design does.
private struct SpendTrendChart: View {
    let months: [SpendHistoryPresentationState.Month]
    let selectedIndex: Int
    let isVisible: Bool
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawProgress: CGFloat = 0

    private let height: CGFloat = 132
    private let topInset: CGFloat = 34
    private let bottomInset: CGFloat = 35
    /// The axis sits below the lowest month so the area fill has somewhere to land.
    private let axisInset: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let points = points(in: proxy.size)
            let axisY = height - axisInset
            let selected = points.indices.contains(selectedIndex) ? points[selectedIndex] : .zero

            ZStack(alignment: .topLeading) {
                areaPath(points, axisY: axisY)
                    .fill(
                        // A flat wash goes grey against the warm page; fading it out keeps it green.
                        LinearGradient(
                            colors: [RenewaTheme.sage.opacity(0.2), RenewaTheme.sage.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(drawProgress)

                Path { path in
                    path.move(to: CGPoint(x: selected.x, y: topInset - 16))
                    path.addLine(to: CGPoint(x: selected.x, y: axisY))
                }
                .stroke(RenewaTheme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                Path { path in
                    path.move(to: CGPoint(x: points.first?.x ?? 0, y: axisY))
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: axisY))
                }
                .stroke(RenewaTheme.divider.opacity(0.8), lineWidth: 1)

                linePath(points)
                    .trim(from: 0, to: drawProgress)
                    .stroke(
                        RenewaTheme.sage,
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                    )

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(RenewaTheme.sageLight)
                        .frame(width: 6, height: 6)
                        .position(point)
                        .opacity(index == selectedIndex ? 0 : drawProgress)
                }

                Circle()
                    .fill(RenewaTheme.background)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(RenewaTheme.sage, lineWidth: 3).frame(width: 12, height: 12))
                    .position(selected)
                    .opacity(drawProgress)

                Text(months[safe: selectedIndex]?.totalText ?? "")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(RenewaTheme.ink)
                    .contentTransition(.numericText())
                    .fixedSize()
                    .frame(width: 0, alignment: labelAlignment)
                    .offset(x: selected.x, y: selected.y - 30)
                    .opacity(drawProgress)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.quick, value: selectedIndex)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSelect(
                            SpendHistoryPresentationState.index(
                                forXFraction: fraction(forX: value.location.x, width: proxy.size.width),
                                count: months.count
                            )
                        )
                    }
            )
        }
        .frame(height: height)
        .sensoryFeedback(.selection, trigger: selectedIndex)
        .accessibilityElement()
        .accessibilityLabel("Monthly commitment trend")
        .accessibilityValue(
            months[safe: selectedIndex].map { "\($0.fullLabel), \($0.totalText)" } ?? ""
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect(min(selectedIndex + 1, months.count - 1))
            case .decrement: onSelect(max(selectedIndex - 1, 0))
            @unknown default: break
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else {
                drawProgress = 1
                return
            }
            drawProgress = 0
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.95)) { drawProgress = 1 }
        }
    }

    /// Undoes the half-slot offset in `points(in:)`, so a touch maps back onto the plotted series.
    private func fraction(forX x: CGFloat, width: CGFloat) -> Double {
        guard months.count > 1, width > 0 else { return 0 }
        let slot = Double(x / width) * Double(months.count) - 0.5
        return slot / Double(months.count - 1)
    }

    /// Points sit at the centre of equal slices, so each one lines up with its label below.
    private func points(in size: CGSize) -> [CGPoint] {
        let plotHeight = height - topInset - bottomInset
        return months.enumerated().map { index, month in
            CGPoint(
                x: size.width * (Double(index) + 0.5) / Double(months.count),
                y: topInset + plotHeight * (1 - month.y)
            )
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    private func areaPath(_ points: [CGPoint], axisY: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: axisY))
            path.addLine(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: axisY))
            path.closeSubpath()
        }
    }

    /// A zero-width frame lets the figure spill in one direction, so the end months stay on screen.
    private var labelAlignment: Alignment {
        if selectedIndex == 0 { return .leading }
        if selectedIndex == months.count - 1 { return .trailing }
        return .center
    }
}

// MARK: - Finding detail

private struct FindingDetailSheet: View {
    let finding: InsightsSummaryPresentationState.Finding
    let footnote: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                HeroIcon(.sparkles, style: .solid, size: 19)
                    .foregroundStyle(RenewaTheme.sage)
                    .frame(width: 42, height: 42)
                    .background(RenewaTheme.sageTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title)
                        .font(.renewa(19, weight: .bold))
                        .foregroundStyle(RenewaTheme.ink)
                    Text(finding.body)
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.mutedBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !finding.rows.isEmpty {
                VStack(spacing: 12) {
                    ForEach(finding.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.label)
                                .font(.renewa(14, weight: row.isEmphasis ? .semibold : .regular))
                                .foregroundStyle(row.isEmphasis ? RenewaTheme.ink : RenewaTheme.muted)
                            Spacer(minLength: 8)
                            Text(row.valueText)
                                .font(.system(size: 19, weight: .regular, design: .serif))
                                .foregroundStyle(RenewaTheme.ink)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 22)
            }

            if let footnote {
                Rectangle()
                    .fill(RenewaTheme.divider.opacity(0.7))
                    .frame(height: 1)
                    .padding(.vertical, 20)
                Text(footnote)
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(RenewaTheme.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.renewa(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 52)
                    .background(RenewaTheme.sage, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RenewaTheme.background)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Empty and loading states

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
        VStack(alignment: .leading, spacing: 11) {
            RenewaSkeleton(height: 15, cornerRadius: 6)
            RenewaSkeleton(width: 232, height: 15, cornerRadius: 6)
            RenewaSkeleton(height: 11, cornerRadius: 5)
            RenewaSkeleton(width: 190, height: 11, cornerRadius: 5)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if DEBUG
    #Preview("Insights") {
        InsightsView(onAddSubscription: {}, onScanInbox: {})
            .environment(RenewaPreviewFixture.store())
    }
#endif
