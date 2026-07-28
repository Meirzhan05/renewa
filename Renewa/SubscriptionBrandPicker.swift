import SwiftUI

struct SubscriptionBrandPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let subscriptionName: String
    let tintHex: String
    let onSave: (String?) async -> Bool

    @State private var selectedBrandID: String?
    @State private var isSaving = false

    init(
        subscriptionName: String,
        tintHex: String,
        initialBrandID: String?,
        onSave: @escaping (String?) async -> Bool
    ) {
        self.subscriptionName = subscriptionName
        self.tintHex = tintHex
        self.onSave = onSave
        _selectedBrandID = State(initialValue: initialBrandID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Choose logo")
                            .font(.renewa(29, weight: .bold))
                        Text("Choose a reviewed brand, or keep a personal initial for \(displayName).")
                            .font(.renewa(15, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                    }

                    option(
                        title: "Use subscription initial",
                        subtitle: "No company logo",
                        brandID: SubscriptionBrand.fallbackOverrideID
                    )

                    Text("REVIEWED BRANDS")
                        .font(.renewa(12, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(RenewaTheme.muted.opacity(0.7))
                        .padding(.top, 4)

                    VStack(spacing: 10) {
                        ForEach(SubscriptionBrand.reviewedBrands) { brand in
                            option(
                                title: brand.displayName,
                                subtitle: brand.logoDevDomain,
                                brandID: brand.id
                            )
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 100)
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
                Button {
                    Task { await save() }
                } label: {
                    RenewaPrimaryActionLabel(
                        title: "Use this logo",
                        pendingTitle: "Saving logo…",
                        isPending: isSaving,
                        icon: .checkCircle
                    )
                    .font(.renewa(17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 57)
                    .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(isSaving)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var displayName: String {
        let trimmed = subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this subscription" : trimmed
    }

    private func option(title: String, subtitle: String, brandID: String?) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                selectedBrandID = brandID
            }
        } label: {
            HStack(spacing: 14) {
                SubscriptionBrandIcon(subscription: previewSubscription(brandID: brandID), size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.renewa(16, weight: .bold))
                    Text(subtitle)
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                }

                Spacer()

                HeroIcon(.checkCircle, style: .solid, size: 22)
                    .foregroundStyle(selectedBrandID == brandID ? RenewaTheme.sage : .clear)
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(12)
            .background(
                selectedBrandID == brandID ? RenewaTheme.sage.opacity(0.1) : RenewaTheme.surface,
                in: RoundedRectangle(cornerRadius: 19, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(selectedBrandID == brandID ? RenewaTheme.sage.opacity(0.42) : .white.opacity(0.6), lineWidth: 1)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selectedBrandID == brandID ? .isSelected : [])
    }

    private func previewSubscription(brandID: String?) -> Subscription {
        Subscription(
            id: UUID(),
            name: displayName,
            price: 0,
            currency: "USD",
            billingCycle: .monthly,
            nextRenewalDate: .now,
            category: .other,
            status: .active,
            iconName: String(displayName.prefix(1)).uppercased(),
            brandID: brandID,
            tintHex: tintHex,
            source: "manual"
        )
    }

    private func save() async {
        isSaving = true
        if await onSave(selectedBrandID) {
            dismiss()
        }
        isSaving = false
    }
}
