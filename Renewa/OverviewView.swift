import SwiftUI

struct OverviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onScanInbox: () -> Void
    let onAddSuggestion: (String) -> Void

    @State private var period: HomePresentationState.Period = .month
    @State private var appeared = false
    @State private var removingSubscriptionIDs = Set<UUID>()
    @State private var removalNotice: RemovalNotice?
    @State private var removalFeedbackCount = 0
    @State private var removalSuccessFeedbackCount = 0
    @State private var subscriptionForBrandSelection: Subscription?
    @Namespace private var periodSelection

    private var home: HomePresentationState {
        HomePresentationState(
            period: period,
            displayName: store.displayName,
            inputs: store.activeSubscriptions.map { subscription in
                .init(
                    subscription: subscription,
                    convertedMonthlyCost: store.convertedMonthlyCost(for: subscription),
                    convertedPrice: subscription.currency == store.defaultCurrency
                        ? subscription.price
                        : store.convertedAmount(subscription.price, from: subscription.currency)
                )
            },
            displayCurrency: store.defaultCurrency,
            previousPeriod: previousPeriod,
            conversionNote: conversionNote,
            suggestions: suggestions
        )
    }

    var body: some View {
        let home = home

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(home)
                    .renewaEntrance(appeared, delay: 0.02)

                spendCard(home)
                    .padding(.top, 22)
                    .renewaEntrance(appeared, delay: 0.08)

                sectionHeader(home)
                    .padding(.top, 28)
                    .renewaEntrance(appeared, delay: 0.14)

                subscriptions(home)
                    .padding(.top, 14)

                if !home.suggestions.isEmpty {
                    suggestionCard(home)
                        .padding(.top, 12)
                        .renewaEntrance(appeared, delay: 0.3)
                }

                if !store.inactiveSubscriptions.isEmpty {
                    inactiveSubscriptions
                        .padding(.top, 30)
                        .renewaEntrance(appeared, delay: 0.36)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .overlay(alignment: .bottom) {
            if let removalNotice {
                removalToast(removalNotice)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(removalAnimation, value: removalNotice)
        .sensoryFeedback(.impact(weight: .medium), trigger: removalFeedbackCount)
        .sensoryFeedback(.success, trigger: removalSuccessFeedbackCount)
        .refreshable {
            do {
                try await store.refreshData()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $subscriptionForBrandSelection) { subscription in
            SubscriptionBrandPicker(
                subscriptionName: subscription.name,
                tintHex: subscription.tintHex,
                initialBrandID: subscription.brandID
            ) { brandID in
                await store.updateBrand(for: subscription, brandID: brandID)
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(30)
        }
        .onAppear {
            appeared = true
        }
    }

    // MARK: - Header

    private func header(_ home: HomePresentationState) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(home.greeting)
                    .font(.renewa(15, weight: .medium))
                    .foregroundStyle(RenewaTheme.mutedSoft)
                Text(home.monthTitle)
                    .font(.renewa(28, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
            }
            Spacer()
            NavigationLink {
                PaymentCalendarView()
            } label: {
                HeroIcon(.calendar, size: 21)
                    .foregroundStyle(RenewaTheme.muted)
                    .frame(width: 42, height: 42)
                    .background(RenewaTheme.divider.opacity(0.42), in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .scaleEffect(appeared ? 1 : 0.72)
            .rotationEffect(.degrees(appeared ? 0 : -12))
            .animation(RenewaMotion.gentle.delay(0.12), value: appeared)
            .accessibilityLabel("Upcoming payments calendar")
            .accessibilityHint("Shows upcoming subscription renewal dates")
        }
    }

    // MARK: - Spend card

    private func spendCard(_ home: HomePresentationState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(home.periodLabel.uppercased())
                    .font(.renewa(12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RenewaTheme.mutedSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
                periodPicker
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(home.totalText)
                    .font(.system(size: 52, weight: .medium, design: .serif))
                    .foregroundStyle(RenewaTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                if let deltaLabel = home.deltaLabel {
                    Text(deltaLabel)
                        .font(.renewa(13, weight: .bold))
                        .foregroundStyle(deltaColor(home.deltaDirection))
                        .lineLimit(1)
                        .padding(.bottom, 6)
                }
            }
            .padding(.top, 12)

            Text(home.subtitle)
                .font(.renewa(14, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .padding(.top, 8)

            if let conversionNote = home.conversionNote {
                Text(conversionNote)
                    .font(.renewa(12, weight: .medium))
                    .foregroundStyle(RenewaTheme.mutedSoft)
                    .padding(.top, 3)
            }

            if !home.segments.isEmpty {
                segmentBar(home.segments)
                    .padding(.top, 18)
                legend(home.segments)
                    .padding(.top, 12)
            }

            if let nextCharge = home.nextCharge {
                Divider()
                    .overlay(RenewaTheme.hairline)
                    .padding(.top, 16)

                nextChargeRow(nextCharge)
                    .padding(.top, 14)
            }
        }
        .padding(22)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: RenewaTheme.ink.opacity(0.07), radius: 20, y: 10)
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach(HomePresentationState.Period.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.quick) {
                        period = item
                    }
                } label: {
                    Text(item.title)
                        .font(.renewa(13, weight: .bold))
                        .foregroundStyle(period == item ? RenewaTheme.ink : RenewaTheme.mutedSoft)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background {
                            if period == item {
                                Capsule()
                                    .fill(RenewaTheme.surface)
                                    .shadow(color: RenewaTheme.ink.opacity(0.12), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "homePeriod", in: periodSelection)
                            }
                        }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(period == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RenewaTheme.background, in: Capsule())
    }

    private func segmentBar(_ segments: [HomePresentationState.Segment]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: SpendSegmentLayout.gap) {
                ForEach(
                    Array(
                        zip(
                            segments,
                            SpendSegmentLayout.widths(
                                for: segments.map(\.fraction),
                                available: geometry.size.width
                            )
                        )
                    ),
                    id: \.0.id
                ) { segment, width in
                    Capsule()
                        .fill(segment.category.color)
                        .frame(width: appeared ? width : 0)
                }
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : RenewaMotion.gentle.delay(0.16), value: appeared)
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending split by category")
        .accessibilityValue(
            segments.map { "\($0.category.title) \($0.shareLabel)" }.joined(separator: ", ")
        )
    }

    private func legend(_ segments: [HomePresentationState.Segment]) -> some View {
        FlowLayout(spacing: 14, lineSpacing: 8) {
            ForEach(segments) { segment in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.category.color)
                        .frame(width: 9, height: 9)
                    Text(segment.category.title)
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                    Text(segment.shareLabel)
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func nextChargeRow(_ next: HomePresentationState.NextCharge) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(next.isUrgent ? RenewaTheme.coral : RenewaTheme.sage)
                .frame(width: 8, height: 8)
            Text(next.summary)
                .font(.renewa(14, weight: .semibold))
                .foregroundStyle(RenewaTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(next.priceText)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundStyle(RenewaTheme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next charge: \(next.summary), \(next.priceText)")
    }

    // MARK: - Subscriptions

    private func sectionHeader(_ home: HomePresentationState) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("All subscriptions")
                .font(.renewa(17, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
            Spacer()
            Text(home.countLabel)
                .font(.renewa(13, weight: .semibold))
                .foregroundStyle(RenewaTheme.mutedSoft)
        }
    }

    @ViewBuilder
    private func subscriptions(_ home: HomePresentationState) -> some View {
        if store.isLoadingSubscriptions && !store.hasLoadedSubscriptions {
            RenewaDelayedSkeleton(accessibilityLabel: "Loading subscriptions") {
                VStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        SubscriptionCardSkeleton()
                    }
                }
            }
        } else if home.cards.isEmpty {
            emptyState
        } else {
            VStack(spacing: 12) {
                ForEach(Array(home.cards.enumerated()), id: \.element.id) { index, card in
                    if !removingSubscriptionIDs.contains(card.id) {
                        SubscriptionCard(card: card)
                            .renewaEntrance(appeared, delay: 0.2 + Double(index) * 0.045, distance: 10)
                            .transition(subscriptionRemovalTransition)
                            .contextMenu {
                                subscriptionActions(card.subscription, removeTitle: "Remove")
                            }
                    }
                }
            }
            .animation(removalAnimation, value: removingSubscriptionIDs)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            HeroIcon(.sparkles, style: .solid, size: 30)
                .foregroundStyle(RenewaTheme.sage)
            Text("Nothing tracked yet")
                .font(.renewa(17, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)
            Text("Add one by hand, or let a scan of your inbox find what you already pay for.")
                .font(.renewa(14, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 18)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func suggestionCard(_ home: HomePresentationState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Missing something?")
                    .font(.renewa(15, weight: .bold))
                    .foregroundStyle(RenewaTheme.muted)
                Spacer()
                Button("Scan inbox", action: onScanInbox)
                    .font(.renewa(13, weight: .semibold))
                    .foregroundStyle(RenewaTheme.sage)
                    .buttonStyle(PressScaleStyle())
            }

            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(home.suggestions) { suggestion in
                    Button {
                        onAddSuggestion(suggestion.name)
                    } label: {
                        HStack(spacing: 6) {
                            HeroIcon(.plus, size: 13)
                                .foregroundStyle(RenewaTheme.mutedSoft)
                            Text(suggestion.name)
                                .font(.renewa(13.5, weight: .semibold))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                        .padding(.leading, 11)
                        .padding(.trailing, 14)
                        .frame(height: 36)
                        .background(RenewaTheme.surface, in: Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Add \(suggestion.name)")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    RenewaTheme.divider,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
    }

    private var inactiveSubscriptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inactive")
                .font(.renewa(17, weight: .bold))
                .foregroundStyle(RenewaTheme.ink)

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
                if !removingSubscriptionIDs.contains(subscription.id) {
                    InactiveSubscriptionRow(
                        subscription: subscription,
                        priceText: inactivePriceText(for: subscription)
                    )
                    .renewaEntrance(appeared, delay: 0.4 + Double(index) * 0.045, distance: 10)
                    .transition(subscriptionRemovalTransition)
                    .contextMenu {
                        subscriptionActions(subscription, removeTitle: "Delete permanently")
                    }
                }
            }
            .animation(removalAnimation, value: removingSubscriptionIDs)
        }
    }

    @ViewBuilder
    private func subscriptionActions(_ subscription: Subscription, removeTitle: String) -> some View {
        Button {
            subscriptionForBrandSelection = subscription
        } label: {
            Label {
                Text("Change logo")
            } icon: {
                HeroIcon(.rectangleStack, size: 18)
            }
        }

        Button(role: .destructive) {
            remove(subscription)
        } label: {
            Label {
                Text(removeTitle)
            } icon: {
                HeroIcon(.trash, size: 18)
            }
        }
    }

    // MARK: - Store-derived inputs

    /// The most recent closed month Renewa has a snapshot for, converted into the display currency.
    private var previousPeriod: (amount: Decimal, label: String)? {
        let calendar = Calendar.current
        guard let currentMonthStart = calendar.dateInterval(of: .month, for: .now)?.start else { return nil }

        let earlier = store.spendingSnapshots.filter { $0.periodStart < currentMonthStart }
        guard let latest = earlier.map(\.periodStart).max() else { return nil }

        let totals =
            earlier
            .filter { $0.periodStart == latest }
            .compactMap(store.convertedMonthlyCost(for:))
        guard !totals.isEmpty else { return nil }

        return (totals.reduce(0, +), latest.formatted(.dateTime.month(.wide)))
    }

    private var conversionNote: String? {
        if store.isRefreshingExchangeRates {
            return "Updating exchange rates"
        }
        if store.unavailableConversionCount > 0 {
            let count = store.unavailableConversionCount
            return "\(count) amount\(count == 1 ? "" : "s") unavailable in \(store.defaultCurrency)"
        }
        if store.foreignCurrencySubscriptionCount > 0 {
            return "Converted to \(store.defaultCurrency)"
        }
        return nil
    }

    /// Familiar services Renewa hasn't seen yet — offered only while the list is short enough to need them.
    private var suggestions: [HomePresentationState.Suggestion] {
        guard store.activeSubscriptions.count <= HomePresentationState.suggestionSubscriptionCeiling else {
            return []
        }
        let tracked = Set(store.subscriptions.compactMap { SubscriptionBrand.resolve($0.name)?.id })
        return SubscriptionBrand.reviewedBrands
            .filter { !tracked.contains($0.id) }
            .prefix(3)
            .map { .init(id: $0.id, name: $0.displayName) }
    }

    private func inactivePriceText(for subscription: Subscription) -> String {
        guard subscription.currency != store.defaultCurrency,
            let converted = store.convertedAmount(subscription.price, from: subscription.currency)
        else {
            return subscription.price.currencyText(code: subscription.currency)
        }
        return converted.currencyText(code: store.defaultCurrency)
    }

    private func deltaColor(_ direction: HomePresentationState.SpendDirection) -> Color {
        switch direction {
        case .up: RenewaTheme.coral
        case .down: RenewaTheme.sage
        case .flat: RenewaTheme.mutedSoft
        }
    }

    // MARK: - Removal

    private var removalAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.4, dampingFraction: 0.94)
    }

    private var subscriptionRemovalTransition: AnyTransition {
        reduceMotion ? .opacity : .subscriptionRemoval
    }

    private func remove(_ subscription: Subscription) {
        guard !removingSubscriptionIDs.contains(subscription.id) else { return }

        removalFeedbackCount += 1
        withAnimation(removalAnimation) {
            _ = removingSubscriptionIDs.insert(subscription.id)
        }

        Task {
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(220))
            }

            let wasRemoved = await store.remove(subscription)
            guard wasRemoved else {
                withAnimation(removalAnimation) {
                    _ = removingSubscriptionIDs.remove(subscription.id)
                }
                return
            }

            presentRemovalNotice(for: subscription)
        }
    }

    private func presentRemovalNotice(for subscription: Subscription) {
        let notice = RemovalNotice(subscriptionName: subscription.name)
        removalSuccessFeedbackCount += 1
        withAnimation(removalAnimation) {
            removalNotice = notice
        }

        Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard removalNotice == notice else { return }
            withAnimation(removalAnimation) {
                removalNotice = nil
            }
        }
    }

    private func removalToast(_ notice: RemovalNotice) -> some View {
        HStack(spacing: 12) {
            HeroIcon(.checkCircle, style: .solid, size: 17)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RenewaTheme.sage, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Subscription removed")
                    .font(.renewa(14, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(notice.subscriptionName)
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.72), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.1), radius: 14, y: 5)
        .accessibilityLabel("Subscription removed: \(notice.subscriptionName)")
    }

    private struct RemovalNotice: Equatable {
        let id = UUID()
        let subscriptionName: String
    }
}

// MARK: - Subscription card

struct SubscriptionCard: View {
    let card: HomePresentationState.Card

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SubscriptionBrandIcon(
                    subscription: card.subscription,
                    size: 46,
                    background: Color(hex: card.subscription.tintHex).opacity(0.16)
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(card.subscription.name)
                            .font(.renewa(17, weight: .bold))
                            .foregroundStyle(RenewaTheme.ink)
                            .lineLimit(1)
                        if card.isUrgent {
                            Text("SOON")
                                .font(.renewa(10, weight: .heavy))
                                .tracking(0.4)
                                .foregroundStyle(RenewaTheme.clay)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(RenewaTheme.clayTint, in: Capsule())
                        }
                    }
                    Text("\(card.categoryLabel) · \(card.cadenceLabel)")
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                        .lineLimit(1)
                }
                // The name earns the room first; a long yearly figure shrinks rather than truncating it.
                .layoutPriority(1)

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(card.periodPriceText)
                        .font(.system(size: 20, weight: .medium, design: .serif))
                        .foregroundStyle(RenewaTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .contentTransition(.numericText())
                    Text(card.nativePriceText ?? card.perLabel)
                        .font(.renewa(12, weight: .semibold))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                        .lineLimit(1)
                }
            }

            Divider()
                .overlay(RenewaTheme.hairline)
                .padding(.top, 14)

            HStack(spacing: 10) {
                CycleTrack(progress: card.cycleProgress, isUrgent: card.isUrgent)
                Text(card.renewLabel)
                    .font(.renewa(13, weight: .semibold))
                    .foregroundStyle(card.isUrgent ? RenewaTheme.clay : RenewaTheme.muted)
                    .lineLimit(1)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        // .contextMenuPreview as well as .interaction: without it the long-press lift is a
        // square-cornered platter and the card's rounded corners read as pale wedges.
        .contentShape(
            [.interaction, .contextMenuPreview],
            RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
    }
}

/// How far through the current billing cycle a subscription is.
private struct CycleTrack: View {
    let progress: Double
    let isUrgent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RenewaTheme.track)
                Capsule()
                    .fill(isUrgent ? RenewaTheme.coral.opacity(0.85) : RenewaTheme.sageLight)
                    .frame(width: geometry.size.width * (filled ? progress : 0))
            }
            .animation(reduceMotion ? nil : RenewaMotion.gentle.delay(0.1), value: filled)
        }
        .frame(height: 6)
        .onAppear { filled = true }
        .accessibilityHidden(true)
    }
}

private struct InactiveSubscriptionRow: View {
    let subscription: Subscription
    let priceText: String

    var body: some View {
        HStack(spacing: 12) {
            SubscriptionBrandIcon(subscription: subscription, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.renewa(16, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(subscription.status.title)
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(RenewaTheme.mutedSoft)
            }
            Spacer()
            Text(priceText)
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(RenewaTheme.muted)
        }
        .opacity(0.62)
        .contentShape(
            [.interaction, .contextMenuPreview],
            RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct SubscriptionCardSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RenewaSkeleton(width: 46, height: 46, cornerRadius: 15)
                VStack(alignment: .leading, spacing: 8) {
                    RenewaSkeleton(width: 128, height: 16, cornerRadius: 7)
                    RenewaSkeleton(width: 88, height: 13, cornerRadius: 6)
                }
                Spacer()
                RenewaSkeleton(width: 58, height: 18, cornerRadius: 7)
            }
            RenewaSkeleton(height: 6, cornerRadius: 3)
                .padding(.top, 26)
        }
        .padding(16)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - Layout helpers

/// Widths for the gapped spend bar: proportional, but never so thin a category disappears.
enum SpendSegmentLayout {
    static let gap: CGFloat = 3
    static let minimumWidth: CGFloat = 10

    static func widths(for fractions: [Double], available: CGFloat) -> [CGFloat] {
        guard !fractions.isEmpty else { return [] }

        let usable = max(available - gap * CGFloat(fractions.count - 1), 0)
        guard usable > 0 else { return fractions.map { _ in 0 } }

        let floor = min(minimumWidth, usable / CGFloat(fractions.count))
        let raw = fractions.map { max(CGFloat($0) * usable, floor) }
        let total = raw.reduce(0, +)
        guard total > usable else { return raw }

        return raw.map { $0 * usable / total }
    }
}

// MARK: - Removal transition

private struct SubscriptionRemovalEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        let settleProgress = min(progress / 0.28, 1)
        let collapseProgress = max((progress - 0.28) / 0.72, 0)

        content
            .opacity(1 - (0.12 * settleProgress) - (0.88 * collapseProgress))
            .scaleEffect(
                x: 1 - (0.02 * settleProgress),
                y: max(0.01, 1 - (0.98 * collapseProgress)),
                anchor: .center
            )
    }
}

private struct SubscriptionRecoveryEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .scaleEffect(
                x: 1 - (0.01 * progress),
                y: 1 - (0.06 * progress),
                anchor: .center
            )
            .offset(x: 14 * progress)
    }
}

private extension AnyTransition {
    static var subscriptionRemoval: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: SubscriptionRecoveryEffect(progress: 1),
                identity: SubscriptionRecoveryEffect(progress: 0)
            ),
            removal: .modifier(
                active: SubscriptionRemovalEffect(progress: 1),
                identity: SubscriptionRemovalEffect(progress: 0)
            )
        )
    }
}

#if DEBUG
    #Preview("Home") {
        NavigationStack {
            OverviewView(onScanInbox: {}, onAddSuggestion: { _ in })
        }
        .environment(RenewaPreviewFixture.store())
    }
#endif
