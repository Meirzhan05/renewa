import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var displayName = ""
    @State private var currency = "USD"
    @State private var avatar: ProfileAvatar = .sage
    @State private var initialized = false

    private let currencyOptions = ["USD", "EUR", "GBP", "KZT", "CAD", "AUD", "JPY"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? RenewaTheme.sage : RenewaTheme.divider)
                        .frame(width: index == step ? 30 : 9, height: 9)
                }
                Spacer()
                Text("\(step + 1) of 3")
                    .font(.renewa(13, weight: .semibold))
                    .foregroundStyle(RenewaTheme.muted)
            }
            .animation(reduceMotion ? nil : RenewaMotion.standard, value: step)
            .padding(.horizontal, 24)
            .padding(.top, 18)

            TabView(selection: $step) {
                introduction
                    .tag(0)
                discovery
                    .tag(1)
                personalization
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : RenewaMotion.standard, value: step)

            Button {
                if step < 2 {
                    withAnimation(reduceMotion ? nil : RenewaMotion.standard) {
                        step += 1
                    }
                } else {
                    Task {
                        _ = await store.completeOnboarding(
                            displayName: displayName,
                            currency: currency,
                            avatar: avatar
                        )
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if store.isBusy {
                        ProgressView().tint(.white)
                    }
                    Text(step == 2 ? "Finish setup" : "Continue")
                        .font(.renewa(17, weight: .semibold))
                    if step < 2 {
                        HeroIcon(.chevronRight, size: 19)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(store.isBusy || (step == 2 && displayName.trimmed.count < 2))
            .opacity(step == 2 && displayName.trimmed.count < 2 ? 0.48 : 1)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(RenewaTheme.background.ignoresSafeArea())
        .onAppear {
            guard !initialized else { return }
            initialized = true
            displayName = store.displayName
            currency = store.defaultCurrency
            avatar = store.profileAvatar
        }
    }

    private var introduction: some View {
        onboardingPage(
            icon: .arrowPath,
            eyebrow: "WELCOME TO RENEWA",
            title: "Everything you pay for, finally in one place.",
            description: "Track renewals, understand monthly spending, and keep forgotten subscriptions from quietly adding up."
        )
    }

    private var discovery: some View {
        onboardingPage(
            icon: .sparkles,
            eyebrow: "INBOX INTELLIGENCE",
            title: "Find subscriptions hiding in your email.",
            description: "Connect an inbox later to detect receipts, renewals, price changes, and cancellations with read-only access."
        )
    }

    private var personalization: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MAKE IT YOURS")
                        .font(.renewa(13, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(RenewaTheme.sage)
                    Text("A few details before we begin.")
                        .font(.renewa(31, weight: .bold))
                    Text("You can change these anytime from your profile.")
                        .font(.renewa(16))
                        .foregroundStyle(RenewaTheme.muted)
                }

                VStack(alignment: .leading, spacing: 11) {
                    Text("Choose an avatar")
                        .font(.renewa(14, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                    avatarPicker
                }

                VStack(alignment: .leading, spacing: 11) {
                    Text("Display name")
                        .font(.renewa(14, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                    TextField("Your name", text: $displayName)
                        .font(.renewa(16))
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 11) {
                    Text("Preferred currency")
                        .font(.renewa(14, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                    Picker("Preferred currency", selection: $currency) {
                        ForEach(currencyOptions, id: \.self) { code in
                            Text(code).tag(code)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 38)
        }
        .scrollIndicators(.hidden)
    }

    private var avatarPicker: some View {
        HStack(spacing: 12) {
            ForEach(ProfileAvatar.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
                        avatar = item
                    }
                } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: 45, height: 45)
                        .overlay {
                            if avatar == item {
                                HeroIcon(.checkCircle, style: .solid, size: 22)
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay {
                            Circle()
                                .stroke(.white, lineWidth: avatar == item ? 3 : 0)
                                .padding(3)
                        }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("\(item.title) avatar")
                .accessibilityAddTraits(avatar == item ? .isSelected : [])
            }
        }
    }

    private func onboardingPage(
        icon: HeroIconName,
        eyebrow: String,
        title: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(RenewaTheme.sage)
                    .frame(width: 116, height: 116)
                    .rotationEffect(.degrees(-5))
                HeroIcon(icon, style: .solid, size: 56)
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(eyebrow)
                    .font(.renewa(13, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(RenewaTheme.sage)
                Text(title)
                    .font(.renewa(34, weight: .bold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(description)
                    .font(.renewa(17))
                    .foregroundStyle(RenewaTheme.muted)
                    .lineSpacing(4)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 38)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
