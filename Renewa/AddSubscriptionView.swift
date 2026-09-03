import SwiftUI

struct AddSubscriptionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: SubscriptionDraft
    @State private var isSaving = false
    @FocusState private var focusedField: SubscriptionFormField?

    /// `prefilledName` seeds the form from a Home suggestion chip; the brand logo still resolves from it.
    init(prefilledName: String? = nil) {
        _draft = State(initialValue: SubscriptionDraft(name: prefilledName ?? "", currency: "USD"))
    }

    var body: some View {
        NavigationStack {
            SubscriptionFormView(
                draft: $draft,
                focusedField: $focusedField,
                validationMessage: validationMessage,
                header: {
                    SubscriptionFormHeader(
                        title: "New subscription",
                        subtitle: "Add the essentials now. You can refine it later."
                    )
                },
                footer: { EmptyView() }
            )
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
            // The account currency lives in the store, which no initializer can reach. Manual entry
            // never lets the user change it, so adopting it as the form appears is enough.
            draft.currency = store.defaultCurrency
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                focusedField = .name
            }
        }
    }

    private var canSave: Bool {
        draft.trimmedName.count >= 2 && (draft.amount ?? 0) > 0 && !isSaving
    }

    private var validationMessage: String? {
        if !draft.priceText.isEmpty, (draft.amount ?? 0) <= 0 {
            return "Enter a price greater than zero."
        }
        return nil
    }

    private var saveButton: some View {
        Button {
            focusedField = nil
            Task { await save() }
        } label: {
            RenewaPrimaryActionLabel(
                title: "Add subscription",
                pendingTitle: "Adding subscription…",
                isPending: isSaving,
                icon: .plus
            )
            .font(.renewa(17, weight: .semibold))
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

    private func save() async {
        guard let amount = draft.amount, amount > 0 else { return }
        withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
            isSaving = true
        }
        if await store.add(draft.subscription(source: "manual")) {
            dismiss()
        } else {
            withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                isSaving = false
            }
        }
    }
}
