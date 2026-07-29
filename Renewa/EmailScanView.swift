import AuthenticationServices
import SwiftUI

struct EmailScanView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webSession: ASWebAuthenticationSession?
    @State private var appeared = false
    @State private var reviewCandidate: EmailSubscriptionCandidate?
    @State private var disconnectTarget: EmailConnectionSummary?
    @State private var showingClearConfirmation = false

    private var presentation: EmailDiscoveryPresentationState {
        EmailDiscoveryPresentationState(status: store.emailScanStatus)
    }

    private var pendingCandidates: [EmailSubscriptionCandidate] {
        store.emailScanStatus?.candidates.filter { $0.reviewStatus == .pending } ?? []
    }

    private var connectedProviders: Set<String> {
        Set(store.emailScanStatus?.connections.map(\.provider) ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .renewaEntrance(appeared, delay: 0.02)
                scanHero
                    .renewaEntrance(appeared, delay: 0.08)
                connectionSection
                    .renewaEntrance(appeared, delay: 0.12)
                if !pendingCandidates.isEmpty {
                    reviewSection
                        .renewaEntrance(appeared, delay: 0.16)
                }
                if let errors = store.emailScanStatus?.errors, !errors.isEmpty {
                    errorSection(errors)
                }
                privacyNote
                    .renewaEntrance(appeared, delay: 0.2)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .task {
            appeared = true
            await store.loadEmailDiscovery()
        }
        .sheet(item: $reviewCandidate) { candidate in
            EmailCandidateReviewSheet(candidate: candidate)
                .presentationDetents([.large])
                .presentationCornerRadius(30)
        }
        .confirmationDialog(
            "Disconnect this inbox?",
            isPresented: Binding(
                get: { disconnectTarget != nil },
                set: { if !$0 { disconnectTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: disconnectTarget
        ) { connection in
            Button("Disconnect \(connection.providerTitle)", role: .destructive) {
                disconnectTarget = nil
                Task { _ = await store.disconnectEmailConnection(connection) }
            }
            Button("Keep connected", role: .cancel) {
                disconnectTarget = nil
            }
        } message: { _ in
            Text("Renewa will remove its encrypted credential and attempt to revoke provider access. Your confirmed subscriptions stay intact.")
        }
        .confirmationDialog(
            "Clear inbox discovery history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear scan history", role: .destructive) {
                Task { _ = await store.clearEmailScanHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scan runs and review history will be removed. Confirmed subscriptions and connected inboxes will remain.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inbox intelligence")
                .font(.renewa(31, weight: .bold))
            Text("AI finds billing events. You decide what changes.")
                .font(.renewa(15))
                .foregroundStyle(RenewaTheme.muted)
        }
    }

    private var scanHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            RenewaTheme.sage.opacity(0.96),
                            Color(red: 0.24, green: 0.43, blue: 0.37),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 18) {
                ZStack {
                    ForEach(0..<3) { index in
                        Circle()
                            .stroke(.white.opacity(0.16 - Double(index) * 0.035), lineWidth: 1)
                            .frame(width: CGFloat(76 + index * 31))
                            .scaleEffect(presentation.isScanning ? 1.1 : 0.94)
                            .animation(
                                reduceMotion || !presentation.isScanning
                                    ? nil
                                    : .easeInOut(duration: 1.05 + Double(index) * 0.16)
                                        .repeatForever(autoreverses: true),
                                value: presentation.isScanning
                            )
                    }
                    HeroIcon(
                        presentation.isScanning ? .sparkles : .envelope,
                        style: .solid,
                        size: 38
                    )
                    .foregroundStyle(.white)
                }
                .frame(height: 126)
                .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text(presentation.headline)
                        .font(.renewa(22, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(presentation.progressText)
                        .font(.renewa(14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .contentTransition(.numericText())
                }

                Button {
                    Task { _ = await store.startEmailScan() }
                } label: {
                    RenewaPrimaryActionLabel(
                        title: presentation.connectionCount == 1 ? "Scan connected inbox" : "Scan connected inboxes",
                        pendingTitle: "Scanning privately…",
                        isPending: presentation.isScanning,
                        icon: .sparkles
                    )
                    .font(.renewa(15, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(!presentation.canStartScan)
                .opacity(presentation.canStartScan || presentation.isScanning ? 1 : 0.52)
            }
            .padding(24)
        }
        .frame(minHeight: 330)
        .shadow(color: RenewaTheme.sage.opacity(0.13), radius: 18, y: 10)
        .accessibilityElement(children: .contain)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connected inboxes")
                    .font(.renewa(19, weight: .bold))
                Spacer()
                if store.emailScanStatus?.scanID != nil {
                    Button("Clear history") {
                        showingClearConfirmation = true
                    }
                    .font(.renewa(12, weight: .semibold))
                    .foregroundStyle(RenewaTheme.muted)
                }
            }

            if store.isLoadingEmailDiscovery && store.emailScanStatus == nil {
                RenewaCard {
                    VStack(spacing: 12) {
                        RenewaSkeleton(height: 18)
                        RenewaSkeleton(height: 14)
                    }
                }
            } else {
                ForEach(store.emailScanStatus?.connections ?? []) { connection in
                    connectionCard(connection)
                }
            }

            if connectedProviders.count < 2 {
                HStack(spacing: 12) {
                    if !connectedProviders.contains("google") {
                        providerButton("Google", mark: "G", provider: "google")
                    }
                    if !connectedProviders.contains("microsoft") {
                        providerButton("Microsoft", mark: "M", provider: "microsoft")
                    }
                }
            }
        }
    }

    private func connectionCard(_ connection: EmailConnectionSummary) -> some View {
        RenewaCard {
            HStack(spacing: 13) {
                Text(connection.provider == "google" ? "G" : "M")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(connection.provider == "google" ? Color.blue : RenewaTheme.sage)
                    .frame(width: 40, height: 40)
                    .background(RenewaTheme.background, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.providerTitle)
                        .font(.renewa(15, weight: .semibold))
                    Text(connection.redactedEmail ?? "Connected inbox")
                        .font(.renewa(13))
                        .foregroundStyle(RenewaTheme.muted)
                    if let lastScannedAt = connection.lastScannedAt {
                        Text("Checked \(lastScannedAt, style: .relative)")
                            .font(.renewa(11, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }

                Spacer()
                Button("Disconnect", role: .destructive) {
                    disconnectTarget = connection
                }
                .font(.renewa(12, weight: .semibold))
                .foregroundStyle(RenewaTheme.coral)
                .disabled(presentation.isScanning)
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review discoveries")
                    .font(.renewa(19, weight: .bold))
                Text("Nothing changes until you confirm it.")
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
            }

            ForEach(pendingCandidates) { candidate in
                candidateCard(candidate)
            }
        }
    }

    private func candidateCard(_ candidate: EmailSubscriptionCandidate) -> some View {
        RenewaCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(candidate.category.color.opacity(0.32))
                        Text(String(candidate.merchantName.prefix(1)).uppercased())
                            .font(.renewa(18, weight: .bold))
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.suggestedAction.title.uppercased())
                            .font(.renewa(10, weight: .bold))
                            .foregroundStyle(RenewaTheme.sage)
                        Text(candidate.merchantName)
                            .font(.renewa(17, weight: .bold))
                        Text(candidate.displayAmount)
                            .font(.renewa(14, weight: .semibold))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                    Spacer()
                }

                Text(candidate.evidence)
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)

                if !candidate.validationIssues.isEmpty {
                    Text(reviewReason(candidate.validationIssues))
                        .font(.renewa(12, weight: .medium))
                        .foregroundStyle(RenewaTheme.coral)
                }

                HStack(spacing: 10) {
                    Button("Ignore") {
                        Task {
                            _ = await store.reviewEmailCandidate(candidate, decision: .ignore)
                        }
                    }
                    .font(.renewa(14, weight: .semibold))
                    .foregroundStyle(RenewaTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RenewaTheme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button("Review") {
                        reviewCandidate = candidate
                    }
                    .font(.renewa(14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(store.isReviewingEmailCandidate)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func errorSection(_ errors: [String]) -> some View {
        RenewaCard {
            HStack(alignment: .top, spacing: 12) {
                HeroIcon(.exclamationTriangle, size: 22)
                    .foregroundStyle(RenewaTheme.coral)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some inboxes need attention")
                        .font(.renewa(15, weight: .bold))
                    ForEach(errors, id: \.self) { error in
                        Text(error)
                            .font(.renewa(12))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Read-only access. Full content is retrieved only for likely billing mail, processed transiently, and never stored by Renewa.")
        } icon: {
            HeroIcon(.lockClosed, size: 20)
        }
        .font(.renewa(13, weight: .medium))
        .foregroundStyle(RenewaTheme.muted)
    }

    private func providerButton(_ title: String, mark: String, provider: String) -> some View {
        Button {
            Task { await connect(provider) }
        } label: {
            HStack(spacing: 8) {
                Text(mark)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(provider == "google" ? Color.blue : RenewaTheme.sage)
                Text("Connect \(title)")
                    .font(.renewa(13, weight: .semibold))
            }
            .foregroundStyle(RenewaTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(presentation.isScanning)
    }

    private func connect(_ provider: String) async {
        do {
            let url = try await store.emailAuthorizationURL(provider: provider)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "renewa") { callbackURL, error in
                Task { @MainActor in
                    if let error {
                        store.errorMessage = error.localizedDescription
                    } else if callbackURL != nil {
                        await store.loadEmailDiscovery()
                    }
                    webSession = nil
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = OAuthPresentationContext.shared
            webSession = session
            session.start()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func reviewReason(_ issues: [String]) -> String {
        if issues.contains("merchant_match_required") {
            return "Check the service and details before adding it."
        }
        if issues.contains("reactivation_requires_review") {
            return "This may reactivate a canceled subscription."
        }
        if issues.contains("low_model_confidence") {
            return "The billing details are less certain."
        }
        if issues.contains(where: { $0.hasPrefix("missing_") }) {
            return "One or more billing details need your input."
        }
        return "Please verify this discovery."
    }
}

private struct EmailCandidateReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let candidate: EmailSubscriptionCandidate

    @State private var edits: EmailCandidateEdits
    @State private var amountText: String

    init(candidate: EmailSubscriptionCandidate) {
        self.candidate = candidate
        let initialEdits = EmailCandidateEdits(candidate: candidate)
        _edits = State(initialValue: initialEdits)
        _amountText = State(initialValue: candidate.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
    }

    private var normalizedEdits: EmailCandidateEdits {
        var value = edits
        value.amount = Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX"))
        value.currency = edits.currency.uppercased()
        return value
    }

    private var issues: [String] {
        EmailDiscoveryPresentationState.confirmationIssues(for: candidate, edits: normalizedEdits)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.suggestedAction.title)
                            .font(.renewa(24, weight: .bold))
                        Text(candidate.evidence)
                            .font(.renewa(14))
                            .foregroundStyle(RenewaTheme.muted)
                    }

                    RenewaCard {
                        VStack(alignment: .leading, spacing: 16) {
                            fieldLabel("Subscription")
                            TextField("Subscription name", text: $edits.merchantName)
                                .textInputAutocapitalization(.words)
                                .renewaField()

                            if candidate.eventType != "canceled" {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        fieldLabel("Amount")
                                        TextField("0.00", text: $amountText)
                                            .keyboardType(.decimalPad)
                                            .renewaField()
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        fieldLabel("Currency")
                                        TextField("USD", text: $edits.currency)
                                            .textInputAutocapitalization(.characters)
                                            .autocorrectionDisabled()
                                            .renewaField()
                                    }
                                }

                                Picker("Billing cycle", selection: $edits.billingCycle) {
                                    ForEach(BillingCycle.allCases) { cycle in
                                        Text(cycle.title).tag(cycle)
                                    }
                                }
                                .font(.renewa(14, weight: .semibold))

                                Picker("Category", selection: $edits.category) {
                                    ForEach(SubscriptionCategory.allCases) { category in
                                        Text(category.title).tag(category)
                                    }
                                }
                                .font(.renewa(14, weight: .semibold))

                                DatePicker(
                                    "Next renewal",
                                    selection: $edits.renewalDate,
                                    displayedComponents: .date
                                )
                                .font(.renewa(14, weight: .semibold))
                            }
                        }
                    }

                    if !issues.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            HeroIcon(.exclamationTriangle, size: 18)
                            Text(issues.joined(separator: " "))
                        }
                        .font(.renewa(13, weight: .medium))
                        .foregroundStyle(RenewaTheme.coral)
                    }

                    Button {
                        Task {
                            let confirmed = await store.reviewEmailCandidate(
                                candidate,
                                decision: .confirm,
                                edits: normalizedEdits
                            )
                            if confirmed { dismiss() }
                        }
                    } label: {
                        RenewaPrimaryActionLabel(
                            title: candidate.eventType == "canceled" ? "Confirm cancellation" : "Confirm discovery",
                            pendingTitle: "Applying confirmed change…",
                            isPending: store.emailCandidatePendingID == candidate.id,
                            icon: .checkCircle
                        )
                        .font(.renewa(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(!issues.isEmpty || store.isReviewingEmailCandidate)
                    .opacity(issues.isEmpty ? 1 : 0.48)
                }
                .padding(24)
                .padding(.bottom, 20)
            }
            .background(RenewaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.renewa(14, weight: .semibold))
                }
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.renewa(10, weight: .bold))
            .foregroundStyle(RenewaTheme.muted)
    }
}

private extension View {
    func renewaField() -> some View {
        self
            .font(.renewa(15, weight: .medium))
            .padding(.horizontal, 13)
            .frame(height: 46)
            .background(RenewaTheme.background, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
