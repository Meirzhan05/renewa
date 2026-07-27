import SwiftUI

struct AddSubscriptionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var price = ""
    @State private var cycle: BillingCycle = .monthly
    @State private var category: SubscriptionCategory = .entertainment
    @State private var renewalDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var isSaving = false
    @State private var appeared = false
    @State private var selectedBrandID: String?
    @State private var hasManuallySelectedBrand = false
    @State private var showingBrandPicker = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case price
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New subscription")
                            .font(.renewa(30, weight: .bold))
                        Text("Add the essentials now. You can refine it later.")
                            .font(.renewa(15))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                    .renewaEntrance(appeared, delay: 0.02)

                    preview
                        .renewaEntrance(appeared, delay: 0.07)

                    sectionCard(title: "Details") {
                        VStack(spacing: 12) {
                            inputField(
                                title: "Subscription name",
                                text: $name,
                                icon: .rectangleStack,
                                field: .name
                            )
                            .textInputAutocapitalization(.words)
                            .focused($focusedField, equals: .name)

                            HStack(spacing: 12) {
                                inputField(
                                    title: "0.00",
                                    text: $price,
                                    icon: .currencyDollar,
                                    field: .price
                                )
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .price)

                                Text(store.defaultCurrency)
                                    .font(.renewa(15, weight: .bold))
                                    .foregroundStyle(RenewaTheme.sage)
                                    .frame(width: 68, height: 54)
                                    .background(
                                        RenewaTheme.sage.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    )
                            }
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.12)

                    if !name.trimmed.isEmpty {
                        sectionCard(title: "Logo") {
                            brandSelection
                        }
                        .renewaEntrance(appeared, delay: 0.15)
                    }

                    sectionCard(title: "Billing cycle") {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(BillingCycle.allCases) { item in
                                selectionTile(
                                    title: item.title,
                                    subtitle: item.cadenceHint,
                                    selected: cycle == item
                                ) {
                                    withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                                        cycle = item
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
                                        category = item
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        HeroIcon(item.heroIcon, size: 20)
                                            .foregroundStyle(category == item ? .white : item.color)
                                        Text(item.title)
                                            .font(.renewa(14, weight: .semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(category == item ? .white : RenewaTheme.ink)
                                    .padding(.horizontal, 13)
                                    .frame(height: 50)
                                    .background(
                                        category == item ? item.color : RenewaTheme.background.opacity(0.8),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                                }
                                .buttonStyle(PressScaleStyle())
                                .accessibilityAddTraits(category == item ? .isSelected : [])
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
                                selection: $renewalDate,
                                in: Date.now.startOfDay...,
                                displayedComponents: .date
                            )
                            .font(.renewa(15, weight: .medium))
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.27)

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.renewa(13, weight: .medium))
                            .foregroundStyle(RenewaTheme.coral)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .background(RenewaTheme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.renewa(15, weight: .semibold))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveButton
            }
        }
        .onAppear {
            appeared = true
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                focusedField = .name
            }
        }
        .sheet(isPresented: $showingBrandPicker) {
            SubscriptionBrandPicker(
                subscriptionName: name.trimmed,
                tintHex: category.defaultTint,
                initialBrandID: effectiveBrandID
            ) { brandID in
                withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                    selectedBrandID = brandID
                    hasManuallySelectedBrand = true
                }
                return true
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(30)
        }
    }

    private var amount: Decimal? {
        Decimal(string: price.replacingOccurrences(of: ",", with: "."))
    }

    private var canSave: Bool {
        name.trimmed.count >= 2 && (amount ?? 0) > 0 && !isSaving
    }

    private var validationMessage: String? {
        if !price.isEmpty, (amount ?? 0) <= 0 {
            return "Enter a price greater than zero."
        }
        return nil
    }

    private var preview: some View {
        HStack(spacing: 15) {
            Group {
                if name.trimmed.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(hex: category.defaultTint))
                        HeroIcon(category.heroIcon, style: .solid, size: 27)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 58, height: 58)
                } else {
                    SubscriptionBrandIcon(subscription: previewSubscription, size: 58)
                }
            }
            .animation(reduceMotion ? nil : RenewaMotion.standard, value: category)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewName)
                    .font(.renewa(17, weight: .bold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text("\(cycle.title) · \(category.title)")
                    .font(.renewa(13, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                    .contentTransition(.opacity)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text((amount ?? 0).currencyText(code: store.defaultCurrency))
                    .font(.renewa(17, weight: .bold))
                    .contentTransition(.numericText())
                Text("per \(cycle.unitLabel)")
                    .font(.renewa(12, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [RenewaTheme.surface, Color(hex: category.defaultTint).opacity(0.08)],
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
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: price)
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: cycle)
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

    private var saveButton: some View {
        Button {
            focusedField = nil
            Task { await save() }
        } label: {
            HStack(spacing: 10) {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    HeroIcon(.plus, style: .solid, size: 21)
                }
                Text(isSaving ? "Adding…" : "Add subscription")
                    .font(.renewa(17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 57)
            .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.48)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
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
        field: Field
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

    private var previewName: String {
        name.trimmed.isEmpty ? "Your subscription" : name.trimmed
    }

    private var automaticBrandID: String? {
        SubscriptionBrand.resolve(name)?.id
    }

    private var effectiveBrandID: String? {
        hasManuallySelectedBrand ? selectedBrandID : automaticBrandID
    }

    private var selectedBrand: SubscriptionBrand? {
        SubscriptionBrand.find(id: effectiveBrandID)
    }

    private var brandSelectionSubtitle: String {
        if selectedBrand != nil, !hasManuallySelectedBrand {
            return "Verified from subscription name"
        }
        return hasManuallySelectedBrand ? "Selected by you" : "No company logo"
    }

    private var previewSubscription: Subscription {
        Subscription(
            id: UUID(),
            name: previewName,
            price: amount ?? 0,
            currency: store.defaultCurrency,
            billingCycle: cycle,
            nextRenewalDate: renewalDate,
            category: category,
            status: .active,
            iconName: String(previewName.prefix(1)).uppercased(),
            brandID: effectiveBrandID,
            tintHex: category.defaultTint,
            source: "manual"
        )
    }

    private func save() async {
        guard let amount, amount > 0 else { return }
        withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
            isSaving = true
        }
        let subscription = Subscription(
            id: UUID(),
            name: name.trimmed,
            price: amount,
            currency: store.defaultCurrency,
            billingCycle: cycle,
            nextRenewalDate: renewalDate,
            category: category,
            status: .active,
            iconName: String(name.trimmed.prefix(1)).uppercased(),
            brandID: effectiveBrandID,
            tintHex: category.defaultTint,
            source: "manual"
        )
        if await store.add(subscription) {
            dismiss()
        } else {
            withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                isSaving = false
            }
        }
    }
}

private extension BillingCycle {
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

private extension SubscriptionCategory {
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

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
