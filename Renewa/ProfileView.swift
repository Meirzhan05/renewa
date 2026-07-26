import SwiftUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var displayName = ""
    @State private var currency = "USD"
    @State private var avatar: ProfileAvatar = .sage
    @State private var initialized = false
    @State private var saveSucceeded = false

    private let currencyOptions = ["USD", "EUR", "GBP", "KZT", "CAD", "AUD", "JPY"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your profile")
                        .font(.renewa(31, weight: .bold))
                    Text("Make Renewa feel like yours.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                }
                .padding(.top, 18)
                .renewaEntrance(appeared, delay: 0.02)

                VStack(spacing: 13) {
                    avatarPreview
                    Text(store.session?.user.email ?? "")
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .renewaEntrance(appeared, delay: 0.08)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Avatar")
                        .font(.renewa(14, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                    avatarPicker
                }
                .renewaEntrance(appeared, delay: 0.12)

                RenewaCard {
                    VStack(alignment: .leading, spacing: 20) {
                        editableField

                        Divider().overlay(RenewaTheme.divider)

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Preferred currency")
                                .font(.renewa(13, weight: .semibold))
                                .foregroundStyle(RenewaTheme.muted)
                            Menu {
                                ForEach(currencyOptions, id: \.self) { code in
                                    Button(code) { currency = code }
                                }
                            } label: {
                                HStack {
                                    HeroIcon(.currencyDollar, size: 21)
                                        .foregroundStyle(RenewaTheme.sage)
                                    Text(currency)
                                        .font(.renewa(16, weight: .semibold))
                                        .foregroundStyle(RenewaTheme.ink)
                                    Spacer()
                                    HeroIcon(.chevronDown, size: 18)
                                        .foregroundStyle(RenewaTheme.muted)
                                }
                                .frame(height: 40)
                                .contentShape(Rectangle())
                            }
                            if currency != store.defaultCurrency {
                                Text("Subscription prices and spending totals will be converted to \(currency). Original amounts stay unchanged.")
                                    .font(.renewa(12, weight: .medium))
                                    .foregroundStyle(RenewaTheme.muted)
                            }
                        }
                    }
                }
                .renewaEntrance(appeared, delay: 0.16)

                Button {
                    Task {
                        if await store.updateProfile(
                            displayName: displayName,
                            currency: currency,
                            avatar: avatar
                        ) {
                            withAnimation(reduceMotion ? nil : RenewaMotion.standard) {
                                saveSucceeded = true
                            }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                                    saveSucceeded = false
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        if store.isBusy {
                            ProgressView().tint(.white)
                        } else if saveSucceeded {
                            HeroIcon(.checkCircle, style: .solid, size: 21)
                        }
                        Text(saveSucceeded ? "Changes saved" : "Save profile")
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
                .renewaEntrance(appeared, delay: 0.2)

                Button(role: .destructive) {
                    Task { await store.signOut() }
                } label: {
                    HStack(spacing: 9) {
                        HeroIcon(.arrowRightStartOnRectangle, size: 21)
                        Text("Sign out")
                            .font(.renewa(16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .buttonStyle(.bordered)
                .tint(RenewaTheme.coral)
                .renewaEntrance(appeared, delay: 0.24)

                if AppConfiguration.current.hasLogoDevPublishableKey,
                   let logoDevURL = URL(string: "https://logo.dev") {
                    Link(destination: logoDevURL) {
                        Text("Logos powered by Logo.dev")
                            .font(.renewa(12, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .renewaEntrance(appeared, delay: 0.28)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .onAppear {
            initializeIfNeeded()
            appeared = true
        }
    }

    private var avatarPreview: some View {
        Circle()
            .fill(avatar.color)
            .frame(width: 96, height: 96)
            .overlay {
                Text(initials)
                    .font(.renewa(31, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(RenewaTheme.ink)
                    .frame(width: 34, height: 34)
                    .overlay {
                        HeroIcon(.camera, size: 18)
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        Circle().stroke(RenewaTheme.background, lineWidth: 3)
                    }
            }
            .animation(reduceMotion ? nil : RenewaMotion.standard, value: avatar)
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
                .accessibilityLabel("\(item.title) avatar")
                .accessibilityAddTraits(avatar == item ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var editableField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Display name")
                .font(.renewa(13, weight: .semibold))
                .foregroundStyle(RenewaTheme.muted)
            HStack(spacing: 11) {
                HeroIcon(.user, size: 21)
                    .foregroundStyle(RenewaTheme.sage)
                TextField("Your name", text: $displayName)
                    .font(.renewa(16, weight: .medium))
                    .textInputAutocapitalization(.words)
                    .textContentType(.name)
            }
            .frame(height: 40)
        }
    }

    private var initials: String {
        let letters = displayName.split(separator: " ").prefix(2).compactMap(\.first)
        let value = letters.map(String.init).joined()
        return value.isEmpty ? "R" : value.uppercased()
    }

    private var hasChanges: Bool {
        displayName.trimmed != store.displayName.trimmed
            || currency != store.defaultCurrency
            || avatar != store.profileAvatar
    }

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        displayName = store.displayName
        currency = store.defaultCurrency
        avatar = store.profileAvatar
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
