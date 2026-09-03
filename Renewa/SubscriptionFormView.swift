import SwiftUI

/// The fields the subscription form can focus. Owned by the presenting screen so it can open the
/// keyboard on the right field and dismiss it before saving.
enum SubscriptionFormField: Hashable {
    case name
    case price
    case currency
}

/// The editable shape of a subscription. Manual creation and agent-discovery review both fill this
/// in, so a subscription is described the same way however it reached the user.
struct SubscriptionDraft: Equatable {
    var name: String
    var priceText: String
    var currency: String
    var billingCycle: BillingCycle
    var category: SubscriptionCategory
    var renewalDate: Date
    /// Only consulted once `hasManuallySelectedBrand` is true. Until the user opens the picker the
    /// logo resolves from the name, so typing "Netflix" shows the Netflix mark without a detour.
    var selectedBrandID: String?
    var hasManuallySelectedBrand: Bool

    init(
        name: String = "",
        priceText: String = "",
        currency: String,
        billingCycle: BillingCycle = .monthly,
        category: SubscriptionCategory = .entertainment,
        renewalDate: Date = SubscriptionDraft.defaultRenewalDate,
        selectedBrandID: String? = nil,
        hasManuallySelectedBrand: Bool = false
    ) {
        self.name = name
        self.priceText = priceText
        self.currency = currency
        self.billingCycle = billingCycle
        self.category = category
        self.renewalDate = renewalDate
        self.selectedBrandID = selectedBrandID
        self.hasManuallySelectedBrand = hasManuallySelectedBrand
    }

    /// Seeds the form from an agent discovery. Anything the extraction left empty falls back to the
    /// same default the manual form opens with, so the two screens never disagree about a blank.
    init(candidate: EmailSubscriptionCandidate) {
        self.init(
            name: candidate.merchantName,
            priceText: candidate.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "",
            currency: candidate.currency ?? "USD",
            billingCycle: candidate.billingCycle ?? .monthly,
            category: candidate.category,
            renewalDate: candidate.renewalDate ?? SubscriptionDraft.defaultRenewalDate
        )
    }

    static var defaultRenewalDate: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parsed with a fixed locale after normalising a decimal comma, so "9,99" and "9.99" both read
    /// as 9.99 whichever keyboard the device offers.
    var amount: Decimal? {
        Decimal(
            string: priceText.replacingOccurrences(of: ",", with: "."),
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    var normalizedCurrency: String {
        currency.uppercased()
    }

    var automaticBrandID: String? {
        SubscriptionBrand.resolve(name)?.id
    }

    var effectiveBrandID: String? {
        hasManuallySelectedBrand ? selectedBrandID : automaticBrandID
    }

    /// What the review sheet sends when confirming a discovery.
    var candidateEdits: EmailCandidateEdits {
        EmailCandidateEdits(
            merchantName: trimmedName,
            amount: amount,
            currency: normalizedCurrency,
            billingCycle: billingCycle,
            renewalDate: renewalDate,
            category: category,
            brandID: effectiveBrandID,
            hasLogoChoice: true
        )
    }

    /// A `Subscription` built from the draft. `name` overrides the typed value only for the preview
    /// card, which needs a placeholder before the user has typed anything.
    func subscription(id: UUID = UUID(), name overrideName: String? = nil, source: String) -> Subscription {
        let resolvedName = overrideName ?? trimmedName
        return Subscription(
            id: id,
            name: resolvedName,
            price: amount ?? 0,
            currency: normalizedCurrency,
            billingCycle: billingCycle,
            nextRenewalDate: renewalDate,
            category: category,
            status: .active,
            iconName: String(resolvedName.prefix(1)).uppercased(),
            brandID: effectiveBrandID,
            tintHex: category.defaultTint,
            source: source
        )
    }
}

/// The "New subscription" form. Manual creation and agent-discovery review both render it so a
/// subscription looks and edits the same however it arrived — the caller supplies only the header
/// that explains where the values came from, an optional footer, and its own submit bar.
struct SubscriptionFormView<Header: View, Footer: View>: View {
    @Binding var draft: SubscriptionDraft
    @FocusState.Binding var focusedField: SubscriptionFormField?
    /// A cancellation confirmation only asks which subscription ended, so the money fields are
    /// hidden — there is nothing left to bill.
    var showsBillingFields: Bool = true
    /// Manual creation always bills in the account currency and shows it as a fixed chip. A
    /// discovery carries whatever currency the receipt used, so review lets the user correct it.
    var currencyIsEditable: Bool = false
    var validationMessage: String?
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var showingBrandPicker = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                    .renewaEntrance(appeared, delay: 0.02)

                preview
                    .renewaEntrance(appeared, delay: 0.07)

                sectionCard(title: "Details") {
                    VStack(spacing: 12) {
                        inputField(
                            title: "Subscription name",
                            text: $draft.name,
                            icon: .rectangleStack,
                            field: .name
                        )
                        .textInputAutocapitalization(.words)

                        if showsBillingFields {
                            HStack(spacing: 12) {
                                inputField(
                                    title: "0.00",
                                    text: $draft.priceText,
                                    icon: .currencyDollar,
                                    field: .price
                                )
                                .keyboardType(.decimalPad)

                                currencyControl
                            }
                        }
                    }
                }
                .renewaEntrance(appeared, delay: 0.12)

                if showsBillingFields, !draft.trimmedName.isEmpty {
                    sectionCard(title: "Logo") {
                        brandSelection
                    }
                    .renewaEntrance(appeared, delay: 0.15)
                }

                if showsBillingFields {
                    sectionCard(title: "Billing cycle") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(BillingCycle.allCases) { item in
                                selectionTile(
                                    title: item.title,
                                    subtitle: item.cadenceHint,
                                    selected: draft.billingCycle == item
                                ) {
                                    withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                                        draft.billingCycle = item
                                    }
                                }
                            }
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.17)

                    sectionCard(title: "Category") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(SubscriptionCategory.allCases) { item in
                                Button {
                                    withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                                        draft.category = item
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        HeroIcon(item.heroIcon, size: 20)
                                            .foregroundStyle(draft.category == item ? .white : item.color)
                                        Text(item.title)
                                            .font(.renewa(14, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(draft.category == item ? .white : RenewaTheme.ink)
                                    .padding(.horizontal, 13)
                                    .frame(height: 50)
                                    .background(
                                        draft.category == item ? item.color : RenewaTheme.background.opacity(0.8),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                                }
                                .buttonStyle(PressScaleStyle())
                                .accessibilityAddTraits(draft.category == item ? .isSelected : [])
                            }
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.22)

                    sectionCard(title: "Next renewal") {
                        HStack(spacing: 12) {
                            HeroIcon(.arrowPath, size: 22)
                                .foregroundStyle(RenewaTheme.sage)
                            DatePicker(
                                "Renewal date",
                                selection: $draft.renewalDate,
                                displayedComponents: .date
                            )
                            .font(.renewa(15, weight: .medium))
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.27)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.coral)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                footer
                    .renewaEntrance(appeared, delay: 0.3)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .onAppear { appeared = true }
        .sheet(isPresented: $showingBrandPicker) {
            SubscriptionBrandPicker(
                subscriptionName: draft.trimmedName,
                tintHex: draft.category.defaultTint,
                initialBrandID: draft.effectiveBrandID
            ) { brandID in
                withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                    draft.selectedBrandID = brandID
                    draft.hasManuallySelectedBrand = true
                }
                return true
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(30)
        }
    }

    private var previewName: String {
        draft.trimmedName.isEmpty ? "Your subscription" : draft.trimmedName
    }

    private var previewSubscription: Subscription {
        draft.subscription(name: previewName, source: "manual")
    }

    private var preview: some View {
        HStack(spacing: 15) {
            Group {
                if draft.trimmedName.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(hex: draft.category.defaultTint))
                        HeroIcon(draft.category.heroIcon, style: .solid, size: 27)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 58, height: 58)
                } else {
                    SubscriptionBrandIcon(subscription: previewSubscription, size: 58)
                }
            }
            .animation(reduceMotion ? nil : RenewaMotion.standard, value: draft.category)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewName)
                    .font(.renewa(17, weight: .bold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(showsBillingFields ? "\(draft.billingCycle.title) · \(draft.category.title)" : draft.category.title)
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                    .contentTransition(.opacity)
            }
            Spacer()
            if showsBillingFields {
                VStack(alignment: .trailing, spacing: 3) {
                    Text((draft.amount ?? 0).currencyText(code: draft.normalizedCurrency))
                        .font(.renewa(17, weight: .bold))
                        .contentTransition(.numericText())
                    Text("per \(draft.billingCycle.unitLabel)")
                        .font(.renewa(12, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [RenewaTheme.surface, Color(hex: draft.category.defaultTint).opacity(0.08)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.7), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: previewName)
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: draft.priceText)
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: draft.billingCycle)
    }

    /// The currency reads as the same chip either way; review just makes it typeable in place so a
    /// EUR receipt does not have to be confirmed as USD.
    @ViewBuilder
    private var currencyControl: some View {
        if currencyIsEditable {
            TextField("USD", text: $draft.currency)
                .font(.renewa(15, weight: .bold))
                .foregroundStyle(RenewaTheme.sage)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .currency)
                .frame(width: 68, height: 54)
                .background(
                    RenewaTheme.sage.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(
                            focusedField == .currency ? RenewaTheme.sage.opacity(0.7) : .clear,
                            lineWidth: 1.5
                        )
                }
        } else {
            Text(draft.normalizedCurrency)
                .font(.renewa(15, weight: .bold))
                .foregroundStyle(RenewaTheme.sage)
                .frame(width: 68, height: 54)
                .background(
                    RenewaTheme.sage.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
        }
    }

    private var brandSelection: some View {
        Button {
            showingBrandPicker = true
        } label: {
            HStack(spacing: 13) {
                SubscriptionBrandIcon(subscription: previewSubscription, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedBrand?.displayName ?? "Subscription initial")
                        .font(.renewa(16, weight: .bold))
                    Text(brandSelectionSubtitle)
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                }

                Spacer()
                HeroIcon(.chevronRight, size: 19)
                    .foregroundStyle(RenewaTheme.muted)
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(12)
            .background(RenewaTheme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityHint("Choose a reviewed brand logo or use the subscription initial.")
    }

    private var selectedBrand: SubscriptionBrand? {
        SubscriptionBrand.find(id: draft.effectiveBrandID)
    }

    private var brandSelectionSubtitle: String {
        if selectedBrand != nil, !draft.hasManuallySelectedBrand {
            return "Verified from subscription name"
        }
        return draft.hasManuallySelectedBrand ? "Selected by you" : "No company logo"
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.renewa(14, weight: .bold))
                .foregroundStyle(RenewaTheme.muted)
            content()
        }
        .padding(17)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
    }

    private func inputField(
        title: String,
        text: Binding<String>,
        icon: HeroIconName,
        field: SubscriptionFormField
    ) -> some View {
        HStack(spacing: 11) {
            HeroIcon(icon, size: 21)
                .foregroundStyle(focusedField == field ? RenewaTheme.sage : RenewaTheme.muted)
            TextField(title, text: text)
                .font(.renewa(16, weight: .medium))
        }
        .padding(.horizontal, 15)
        .frame(height: 54)
        .background(
            RenewaTheme.background.opacity(0.8),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(focusedField == field ? RenewaTheme.sage.opacity(0.7) : .clear, lineWidth: 1.5)
        }
        .focused($focusedField, equals: field)
    }

    private func selectionTile(
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.renewa(15, weight: .bold))
                Text(subtitle)
                    .font(.renewa(11, weight: .medium))
                    .foregroundStyle(selected ? .white.opacity(0.72) : RenewaTheme.muted)
            }
            .foregroundStyle(selected ? .white : RenewaTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 62)
            .background(
                selected ? RenewaTheme.sage : RenewaTheme.background.opacity(0.8),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The title + subtitle block both screens open with, so "New subscription" and a discovery review
/// share one heading treatment.
struct SubscriptionFormHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.renewa(30, weight: .bold))
            Text(subtitle)
                .font(.renewa(15))
                .foregroundStyle(RenewaTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension BillingCycle {
    var cadenceHint: String {
        switch self {
        case .weekly: "Every 7 days"
        case .monthly: "Every month"
        case .quarterly: "Every 3 months"
        case .yearly: "Once a year"
        }
    }

    var unitLabel: String {
        switch self {
        case .weekly: "week"
        case .monthly: "month"
        case .quarterly: "quarter"
        case .yearly: "year"
        }
    }
}

extension SubscriptionCategory {
    var heroIcon: HeroIconName {
        switch self {
        case .entertainment: .sparkles
        case .work: .briefcase
        case .cloud: .cloud
        case .health: .heart
        case .learning: .academicCap
        case .other: .rectangleStack
        }
    }

    var defaultTint: String {
        switch self {
        case .entertainment: "#5A967D"
        case .work: "#6B7357"
        case .cloud: "#6BA5DC"
        case .health: "#D97989"
        case .learning: "#6A83C7"
        case .other: "#8A8175"
        }
    }
}
