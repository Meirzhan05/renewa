import AuthenticationServices
import SwiftUI

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var displayName = ""
    @State private var currency = "USD"
    @State private var avatar: ProfileAvatar = .sage
    @State private var initialized = false
    @State private var webSession: ASWebAuthenticationSession?
    @State private var isConnectingInbox = false
    @State private var inboxConnected = false
    @State private var inboxDecisionMade = false
    @State private var connectedProvider: String?

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
                personalization
                    .tag(1)
                discovery
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
                RenewaPrimaryActionLabel(
                    title: step == 2 ? finishTitle : "Continue",
                    pendingTitle: "Finishing setup…",
                    isPending: store.isBusy,
                    icon: step < 2 ? .chevronRight : nil
                )
                .font(.renewa(17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(store.isBusy || (step == 1 && displayName.trimmed.count < 2) || (step == 2 && !inboxDecisionMade))
            .opacity((step == 1 && displayName.trimmed.count < 2) || (step == 2 && !inboxDecisionMade) ? 0.48 : 1)
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
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(RenewaTheme.sage)
                    .frame(width: 116, height: 116)
                    .rotationEffect(.degrees(-5))
                HeroIcon(.envelope, style: .solid, size: 54)
                    .foregroundStyle(.white)
            }
            Text("INBOX INTELLIGENCE")
                .font(.renewa(13, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(RenewaTheme.sage)
            Text("Would you like us to scan your inbox?")
                .font(.renewa(32, weight: .bold))
            Text("Choose an inbox to privately scan your existing mail for subscriptions. Afterward, Renewa checks new mail once a day for billing changes. Or you can choose not now.")
                .font(.renewa(16))
                .foregroundStyle(RenewaTheme.muted)
                .lineSpacing(4)
            HStack(spacing: 12) {
                inboxButton("Google", provider: "google", mark: "G")
                inboxButton("Microsoft", provider: "microsoft", mark: "M")
            }
            inboxConnectionFeedback
            if !inboxConnected {
                Button {
                    inboxDecisionMade = true
                } label: {
                    Text(inboxDecisionMade ? "You can connect an inbox later" : "Not now")
                        .font(.renewa(15, weight: .semibold))
                        .foregroundStyle(RenewaTheme.sage)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(PressScaleStyle())
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 38)
    }

    private func inboxButton(_ title: String, provider: String, mark: String) -> some View {
        Button {
            Task { await connectInbox(provider) }
        } label: {
            HStack(spacing: 7) {
                Text(mark).font(.system(size: 16, weight: .bold, design: .rounded))
                Text("Connect \(title)")
            }
            .font(.renewa(14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isConnectingInbox)
    }

    private func connectInbox(_ provider: String) async {
        do {
            connectedProvider = provider
            isConnectingInbox = true
            let url = try await store.emailAuthorizationURL(provider: provider)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "renewa") { callbackURL, error in
                Task { @MainActor in
                    defer { isConnectingInbox = false; webSession = nil }
                    if let error { store.errorMessage = error.localizedDescription; return }
                    guard let callbackURL else { return }
                    if let message = inboxAuthorizationError(from: callbackURL) {
                        store.errorMessage = message
                        return
                    }
                    inboxConnected = await store.startEmailScan()
                    inboxDecisionMade = inboxConnected
                }
            }
            session.presentationContextProvider = OAuthPresentationContext.shared
            webSession = session
            session.start()
        } catch {
            isConnectingInbox = false
            store.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var inboxConnectionFeedback: some View {
        if isConnectingInbox {
            connectionFeedbackCard(
                title: "Connecting \(providerTitle)…",
                message: "Finishing the secure connection. You’ll see scan progress here next.",
                icon: .arrowPath,
                isWorking: true
            )
        } else if inboxConnected {
            let status = store.emailScanStatus
            connectionFeedbackCard(
                title: "\(providerTitle) connected",
                message: scanProgressText(status),
                icon: status?.isActive == true ? .sparkles : .checkCircle,
                isWorking: status?.isActive == true
            )
        }
    }

    private var providerTitle: String {
        connectedProvider == "microsoft" ? "Microsoft" : "Google"
    }

    private var finishTitle: String {
        inboxConnected && store.emailScanStatus?.isActive == true
            ? "Continue while scanning"
            : "Finish setup"
    }

    private func scanProgressText(_ status: EmailScanStatus?) -> String {
        guard let status else {
            return "Your inbox is connected. Preparing your first private scan…"
        }
        if status.status == .failed {
            return status.errors.first ?? "The scan needs attention. You can retry it from Inbox Intelligence."
        }
        if status.isActive {
            return "Your first scan is running: \(status.scanned) messages checked and \(status.candidateMessages) billing emails found so far."
        }
        return "Your first scan is complete. You can review any findings in Inbox Intelligence."
    }

    private func connectionFeedbackCard(
        title: String,
        message: String,
        icon: HeroIconName,
        isWorking: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HeroIcon(icon, style: .solid, size: 22)
                .foregroundStyle(RenewaTheme.sage)
                .rotationEffect(.degrees(isWorking && !reduceMotion ? 360 : 0))
                .animation(
                    isWorking && !reduceMotion
                        ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                        : nil,
                    value: isWorking
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.renewa(15, weight: .bold))
                Text(message)
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RenewaTheme.sage.opacity(0.09), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func inboxAuthorizationError(from callbackURL: URL) -> String? {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first(where: { $0.name == "error_description" })?.value
            ?? items?.first(where: { $0.name == "error" })?.value
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
