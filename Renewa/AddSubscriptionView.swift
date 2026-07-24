import SwiftUI

struct AddSubscriptionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var price = ""
    @State private var cycle: BillingCycle = .monthly
    @State private var category: SubscriptionCategory = .entertainment
    @State private var renewalDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var isSaving = false
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Price", text: $price)
                        .keyboardType(.decimalPad)
                }

                Section("Billing") {
                    Picker("Cycle", selection: $cycle) {
                        ForEach(BillingCycle.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    DatePicker("Next renewal", selection: $renewalDate, displayedComponents: .date)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(SubscriptionCategory.allCases) { item in
                            Label(item.title, systemImage: "circle.fill")
                                .tag(item)
                        }
                    }
                }

                Section("Preview") {
                    preview
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving { ProgressView().tint(.white) }
                            Text("Add subscription")
                                .font(.renewa(17, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(RenewaTheme.ink)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || amount == nil || isSaving)
                }
            }
            .scrollContentBackground(.hidden)
            .background(RenewaTheme.background)
            .renewaEntrance(appeared, delay: 0.04, distance: 10)
            .navigationTitle("New subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            appeared = true
        }
    }

    private var amount: Decimal? {
        Decimal(string: price.replacingOccurrences(of: ",", with: "."))
    }

    private var preview: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: category.defaultTint))
                Text(previewInitial)
                    .font(.renewa(previewInitial.count > 1 ? 14 : 20, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
            }
            .frame(width: 50, height: 50)
            .animation(RenewaMotion.standard, value: category)

            VStack(alignment: .leading, spacing: 3) {
                Text(previewName)
                    .font(.renewa(16, weight: .semibold))
                    .contentTransition(.opacity)
                Text(cycle.title)
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
            }
            Spacer()
            Text((amount ?? 0).currencyText(code: store.defaultCurrency))
                .font(.renewa(15, weight: .semibold))
                .contentTransition(.numericText())
        }
        .animation(RenewaMotion.quick, value: previewName)
        .animation(RenewaMotion.quick, value: price)
        .animation(RenewaMotion.quick, value: cycle)
    }

    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your subscription" : trimmed
    }

    private var previewInitial: String {
        let initial = String(previewName.prefix(1)).uppercased()
        return initial.isEmpty ? "S" : initial
    }

    private func save() async {
        guard let amount else { return }
        withAnimation(RenewaMotion.quick) {
            isSaving = true
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscription = Subscription(
            id: UUID(),
            name: trimmed,
            price: amount,
            currency: store.defaultCurrency,
            billingCycle: cycle,
            nextRenewalDate: renewalDate,
            category: category,
            status: .active,
            iconName: String(trimmed.prefix(1)).uppercased(),
            tintHex: category.defaultTint,
            source: "manual"
        )
        if await store.add(subscription) { dismiss() }
        withAnimation(RenewaMotion.quick) {
            isSaving = false
        }
    }
}

private extension SubscriptionCategory {
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
