import SwiftUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var showingProfileEditor = false
    @State private var showingCurrencyPicker = false
    @State private var showingAbout = false
    @State private var showingDeletionConfirmation = false
    @State private var confirmationMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("You")
                        .font(.renewa(31, weight: .bold))
                    Text("Your preferences and account.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                }
                .padding(.top, 18)
                .renewaEntrance(appeared, delay: 0.02)

                Button {
                    showingProfileEditor = true
                } label: {
                    identitySummary
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityHint("Opens profile editing")
                .renewaEntrance(appeared, delay: 0.08)

                settingsSection("PREFERENCES") {
                    settingsRow(
                        icon: .currencyDollar,
                        title: "Preferred currency",
                        value: store.defaultCurrency
                    ) {
                        showingCurrencyPicker = true
                    }
                }
                .renewaEntrance(appeared, delay: 0.14)

                settingsSection("ACCOUNT & SUPPORT") {
                    settingsRow(
                        icon: .rectangleStack,
                        title: "About & licenses",
                        value: nil
                    ) {
                        showingAbout = true
                    }

                    Divider().overlay(RenewaTheme.divider)

                    settingsRow(
                        icon: .arrowRightStartOnRectangle,
                        title: "Sign out",
                        value: nil,
                        tint: RenewaTheme.ink
                    ) {
                        Task { await store.signOut() }
                    }
                }
                .renewaEntrance(appeared, delay: 0.2)

                VStack(alignment: .leading, spacing: 11) {
                    Text("DANGER ZONE")
                        .font(.renewa(12, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(RenewaTheme.coral)

                    Button {
                        showingDeletionConfirmation = true
                    } label: {
                        HStack(spacing: 13) {
                            HeroIcon(.trash, size: 21)
                                .foregroundStyle(RenewaTheme.coral)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Delete account")
                                    .font(.renewa(16, weight: .semibold))
                                    .foregroundStyle(RenewaTheme.coral)
                                Text("Permanently remove your Renewa data")
                                    .font(.renewa(13, weight: .medium))
                                    .foregroundStyle(RenewaTheme.muted)
                            }
                            Spacer()
                            HeroIcon(.chevronRight, size: 18)
                                .foregroundStyle(RenewaTheme.coral.opacity(0.72))
                        }
                        .padding(18)
                        .background(RenewaTheme.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(RenewaTheme.coral.opacity(0.22), lineWidth: 1)
                        }
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Opens permanent account deletion confirmation")
                }
                .renewaEntrance(appeared, delay: 0.26)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .overlay(alignment: .bottom) {
            if let confirmationMessage {
                confirmationToast(confirmationMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: confirmationMessage)
        .sheet(isPresented: $showingProfileEditor) {
            ProfileEditorView { message in
                showConfirmation(message)
            }
            .presentationDetents([.large])
            .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showingCurrencyPicker) {
            CurrencyPickerView { message in
                showConfirmation(message)
            }
            .presentationDetents([.medium])
            .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showingAbout) {
            ProfileAboutView()
                .presentationDetents([.medium])
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showingDeletionConfirmation) {
            DeleteAccountConfirmationView()
                .presentationDetents([.large])
                .presentationCornerRadius(30)
        }
        .onAppear {
            appeared = true
        }
    }

    private var identitySummary: some View {
        HStack(spacing: 16) {
            ProfileMonogram(name: store.displayName, avatar: store.profileAvatar, size: 72)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(RenewaTheme.ink)
                        .frame(width: 26, height: 26)
                        .overlay {
                            HeroIcon(.user, size: 14)
                                .foregroundStyle(.white)
                        }
                        .overlay {
                            Circle().stroke(RenewaTheme.surface, lineWidth: 2)
                        }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.displayName)
                    .font(.renewa(21, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                    .lineLimit(1)
                if let email = store.session?.user.email, !email.isEmpty {
                    Text(email)
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.muted)
                        .lineLimit(1)
                }
                Text("Edit profile")
                    .font(.renewa(14, weight: .semibold))
                    .foregroundStyle(RenewaTheme.sage)
            }
            Spacer(minLength: 8)
            HeroIcon(.chevronRight, size: 20)
                .foregroundStyle(RenewaTheme.muted)
        }
        .padding(18)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.62), lineWidth: 1)
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.renewa(12, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(RenewaTheme.muted)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 18)
            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.62), lineWidth: 1)
            }
        }
    }

    private func settingsRow(
        icon: HeroIconName,
        title: String,
        value: String?,
        tint: Color = RenewaTheme.sage,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                HeroIcon(icon, size: 21)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.renewa(16, weight: .medium))
                    .foregroundStyle(RenewaTheme.ink)
                Spacer()
                if let value {
                    Text(value)
                        .font(.renewa(15, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                }
                HeroIcon(.chevronRight, size: 18)
                    .foregroundStyle(RenewaTheme.muted.opacity(0.72))
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private func confirmationToast(_ message: String) -> some View {
        HStack(spacing: 9) {
            HeroIcon(.checkCircle, style: .solid, size: 20)
                .foregroundStyle(.white)
            Text(message)
                .font(.renewa(14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(RenewaTheme.ink, in: Capsule())
        .shadow(color: RenewaTheme.ink.opacity(0.18), radius: 16, y: 8)
    }

    private func showConfirmation(_ message: String) {
        withAnimation(reduceMotion ? nil : RenewaMotion.standard) {
            confirmationMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                confirmationMessage = nil
            }
        }
    }
}

private struct ProfileEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayName = ""
    @State private var avatar: ProfileAvatar = .sage
    @State private var initialized = false

    let onSaved: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Edit profile")
                            .font(.renewa(28, weight: .bold))
                        Text("Choose the name and color you want to see across Renewa.")
                            .font(.renewa(15))
                            .foregroundStyle(RenewaTheme.muted)
                    }

                    HStack {
                        Spacer()
                        ProfileMonogram(name: displayName, avatar: avatar, size: 104)
                            .animation(reduceMotion ? nil : RenewaMotion.standard, value: avatar)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Display name")
                            .font(.renewa(14, weight: .semibold))
                            .foregroundStyle(RenewaTheme.muted)
                        TextField("Your name", text: $displayName)
                            .font(.renewa(17, weight: .medium))
                            .textInputAutocapitalization(.words)
                            .textContentType(.name)
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Avatar color")
                            .font(.renewa(14, weight: .semibold))
                            .foregroundStyle(RenewaTheme.muted)
                        avatarPicker
                    }

                    Button {
                        Task {
                            if await store.updateProfile(
                                displayName: displayName,
                                currency: store.defaultCurrency,
                                avatar: avatar
                            ) {
                                onSaved("Profile updated")
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if store.isBusy { ProgressView().tint(.white) }
                            Text("Save changes")
                                .font(.renewa(16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 55)
                        .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(!hasChanges || displayName.trimmed.count < 2 || store.isBusy)
                    .opacity(hasChanges && displayName.trimmed.count >= 2 ? 1 : 0.48)
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(RenewaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(RenewaTheme.sage)
                }
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            displayName = store.displayName
            avatar = store.profileAvatar
        }
    }

    private var avatarPicker: some View {
        HStack(spacing: 11) {
            ForEach(ProfileAvatar.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                        avatar = item
                    }
                } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: 44, height: 44)
                        .overlay {
                            if avatar == item {
                                HeroIcon(.checkCircle, style: .solid, size: 22)
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle()
                                .stroke(RenewaTheme.surface, lineWidth: avatar == item ? 3 : 0)
                                .padding(3)
                        }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("\(item.title) avatar color")
                .accessibilityAddTraits(avatar == item ? .isSelected : [])
            }
        }
    }

    private var hasChanges: Bool {
        displayName.trimmed != store.displayName.trimmed || avatar != store.profileAvatar
    }
}

private struct CurrencyPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var savingCurrency: String?

    private let currencyOptions = ["USD", "EUR", "GBP", "KZT", "CAD", "AUD", "JPY"]

    let onSaved: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred currency")
                        .font(.renewa(28, weight: .bold))
                    Text("Totals are shown in this currency. Original subscription amounts stay unchanged.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                }

                VStack(spacing: 0) {
                    ForEach(currencyOptions, id: \.self) { currency in
                        Button {
                            guard currency != store.defaultCurrency, savingCurrency == nil else { return }
                            savingCurrency = currency
                            Task {
                                if await store.updateProfile(
                                    displayName: store.displayName,
                                    currency: currency,
                                    avatar: store.profileAvatar
                                ) {
                                    onSaved("Currency set to \(currency)")
                                    dismiss()
                                }
                                savingCurrency = nil
                            }
                        } label: {
                            HStack {
                                Text(currency)
                                    .font(.renewa(17, weight: .semibold))
                                    .foregroundStyle(RenewaTheme.ink)
                                Spacer()
                                if savingCurrency == currency {
                                    ProgressView()
                                        .tint(RenewaTheme.sage)
                                } else if currency == store.defaultCurrency {
                                    HeroIcon(.checkCircle, style: .solid, size: 21)
                                        .foregroundStyle(RenewaTheme.sage)
                                }
                            }
                            .frame(height: 52)
                        }
                        .buttonStyle(PressScaleStyle())
                        if currency != currencyOptions.last {
                            Divider().overlay(RenewaTheme.divider)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Spacer()
            }
            .padding(24)
            .background(RenewaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(RenewaTheme.sage)
                }
            }
        }
    }
}

private struct ProfileAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                ZStack {
                    Circle()
                        .fill(RenewaTheme.sage)
                        .frame(width: 68, height: 68)
                    HeroIcon(.arrowPath, style: .solid, size: 35)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Renewa")
                        .font(.renewa(29, weight: .bold))
                    Text("A calmer way to keep track of recurring spending.")
                        .font(.renewa(16))
                        .foregroundStyle(RenewaTheme.muted)
                }

                RenewaCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Brand logos")
                            .font(.renewa(17, weight: .semibold))
                        Text("Subscription logos are provided by Logo.dev when a logo is available.")
                            .font(.renewa(14))
                            .foregroundStyle(RenewaTheme.muted)
                        if AppConfiguration.current.hasLogoDevPublishableKey,
                           let logoDevURL = URL(string: "https://logo.dev") {
                            Link("Logos powered by Logo.dev", destination: logoDevURL)
                                .font(.renewa(14, weight: .semibold))
                                .foregroundStyle(RenewaTheme.sage)
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
            .background(RenewaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(RenewaTheme.sage)
                }
            }
        }
    }
}

private struct DeleteAccountConfirmationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(RenewaTheme.coral.opacity(0.13))
                            .frame(width: 72, height: 72)
                        HeroIcon(.trash, size: 33)
                            .foregroundStyle(RenewaTheme.coral)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete your account?")
                            .font(.renewa(28, weight: .bold))
                        Text("This is permanent and cannot be undone.")
                            .font(.renewa(16, weight: .medium))
                            .foregroundStyle(RenewaTheme.coral)
                    }

                    RenewaCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What will be removed")
                                .font(.renewa(17, weight: .semibold))
                            Text("Your profile, subscriptions, connected-inbox credentials, email scan history, billing events, spending snapshots, and cached insights.")
                                .font(.renewa(14))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Type DELETE to confirm")
                            .font(.renewa(14, weight: .semibold))
                            .foregroundStyle(RenewaTheme.muted)
                        TextField("DELETE", text: $confirmationText)
                            .font(.renewa(17, weight: .semibold))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    Button(role: .destructive) {
                        Task {
                            if await store.deleteAccount() {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if store.isBusy { ProgressView().tint(.white) }
                            Text("Permanently delete account")
                                .font(.renewa(16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 55)
                        .background(RenewaTheme.coral, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(confirmationText != "DELETE" || store.isBusy)
                    .opacity(confirmationText == "DELETE" && !store.isBusy ? 1 : 0.48)

                    Button("Cancel") { dismiss() }
                        .font(.renewa(16, weight: .semibold))
                        .foregroundStyle(RenewaTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(RenewaTheme.background)
        }
    }
}

private struct ProfileMonogram: View {
    let name: String
    let avatar: ProfileAvatar
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(avatar.color)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.renewa(size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
            }
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        let value = letters.map(String.init).joined()
        return value.isEmpty ? "R" : value.uppercased()
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
