import AuthenticationServices
import SwiftUI

struct EmailScanView: View {
    @Environment(AppStore.self) private var store
    @State private var webSession: ASWebAuthenticationSession?
    @State private var appeared = false
    @State private var reviewCandidate: EmailSubscriptionCandidate?
    @State private var suppressionCandidate: EmailSubscriptionCandidate?
    @State private var disconnectTarget: EmailConnectionSummary?
    @State private var learningItem: EmailScanLearningItem?
    @State private var showingClearConfirmation = false
    @State private var showingInboxSettings = false
    @State private var showingScanDetails = false

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
            VStack(alignment: .leading, spacing: 20) {
                header
                    .renewaEntrance(appeared, delay: 0.02)
                if store.isLoadingEmailDiscovery && store.emailScanStatus == nil {
                    dashboardLoading
                    .renewaEntrance(appeared, delay: 0.08)
                } else {
                    assistantStatus
                        .renewaEntrance(appeared, delay: 0.08)
                    if let latestCheck = presentation.latestCheck {
                        latestCheckSection(latestCheck)
                            .renewaEntrance(appeared, delay: 0.1)
                    }
                    if !pendingCandidates.isEmpty {
                        reviewSection
                            .renewaEntrance(appeared, delay: 0.14)
                    }
                }
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
        .sheet(item: $learningItem) { item in
            EmailScanLearningDetailSheet(item: item)
                .presentationDetents([.medium])
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showingInboxSettings) {
            inboxSettingsSheet
                .presentationDetents([.large])
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showingScanDetails) {
            NavigationStack {
                scanDetailsView
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingScanDetails = false }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationCornerRadius(30)
        }
        .confirmationDialog(
            "Stop suggestions from \(suppressionCandidate?.merchantName ?? "this service")?",
            isPresented: Binding(
                get: { suppressionCandidate != nil },
                set: { if !$0 { suppressionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: suppressionCandidate
        ) { candidate in
            Button("I don’t use this", role: .destructive) {
                suppressionCandidate = nil
                Task { _ = await store.suppressEmailCandidate(candidate) }
            }
            Button("Keep reviewing", role: .cancel) {
                suppressionCandidate = nil
            }
        } message: { candidate in
            Text("Renewa will stop suggesting \(candidate.merchantName) from inbox evidence. This does not cancel or change any subscription.")
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Inbox intelligence")
                    .font(.renewa(31, weight: .bold))
                Text("Subscription activity from your connected inboxes.")
                    .font(.renewa(15))
                    .foregroundStyle(RenewaTheme.muted)
            }
            Spacer(minLength: 8)
            Button {
                showingInboxSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(RenewaTheme.surface, in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Inbox settings")
            .accessibilityHint("Opens inbox connections, alerts, and scan details")
        }
    }

    private var dashboardLoading: some View {
        RenewaCard {
            HStack(alignment: .top, spacing: 15) {
                ZStack {
                    Circle()
                        .fill(RenewaTheme.sage.opacity(0.13))
                    HeroIcon(.envelope, style: .solid, size: 25)
                        .foregroundStyle(RenewaTheme.sage)
                }
                .frame(width: 54, height: 54)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    Text("Preparing Inbox Intelligence")
                        .font(.renewa(17, weight: .bold))
                    Text("Checking your connected inboxes and scan history.")
                        .font(.renewa(13))
                        .foregroundStyle(RenewaTheme.muted)
                    HStack(spacing: 8) {
                        RenewaSkeleton(width: 58, height: 10, cornerRadius: 5)
                        RenewaSkeleton(width: 86, height: 10, cornerRadius: 5)
                        RenewaSkeleton(width: 68, height: 10, cornerRadius: 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading inbox intelligence")
    }

    private var assistantStatus: some View {
        RenewaCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 13) {
                    HeroIcon(statusIcon, style: .solid, size: 25)
                        .foregroundStyle(statusTint)
                        .frame(width: 34, height: 34)
                        .background(statusTint.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assistantTitle)
                            .font(.renewa(18, weight: .bold))
                        Text(assistantMessage)
                            .font(.renewa(13))
                            .foregroundStyle(RenewaTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if presentation.isScanning {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(presentation.stageTitle) · \(presentation.scanned) messages checked")
                            .font(.renewa(13, weight: .semibold))
                            .foregroundStyle(RenewaTheme.ink)
                        Text("You can leave this tab. The scan continues safely in the background.")
                            .font(.renewa(12))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }

                if needsSettingsAction {
                    Button(statusActionTitle) {
                        performStatusAction()
                    }
                    .font(.renewa(14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pendingCandidates.count == 1 ? "One change to review" : "\(pendingCandidates.count) changes to review")
                    .font(.renewa(20, weight: .bold))
                Text("Nothing changes until you confirm it.")
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
            }
            ForEach(pendingCandidates) { candidate in
                candidateCard(candidate)
            }
        }
    }

    private func latestCheckSection(_ latestCheck: EmailLatestCheckSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Latest check")
                    .font(.renewa(19, weight: .bold))
                Spacer()
                Button("Scan details") {
                    showingScanDetails = true
                }
                .font(.renewa(13, weight: .semibold))
                .foregroundStyle(RenewaTheme.sage)
                .accessibilityHint("Opens privacy-safe inbox scan details")
            }

            RenewaCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        HeroIcon(.envelope, size: 20)
                            .foregroundStyle(RenewaTheme.sage)
                            .frame(width: 36, height: 36)
                            .background(RenewaTheme.sage.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(latestCheck.inboxLabel)
                                .font(.renewa(15, weight: .semibold))
                            Text("Checked \(latestCheck.completedAt.formatted(.relative(presentation: .named)))")
                                .font(.renewa(12))
                                .foregroundStyle(RenewaTheme.muted)
                        }
                    }

                    Text(latestCheck.outcome)
                        .font(.renewa(14, weight: .medium))
                        .foregroundStyle(RenewaTheme.ink)

                    if latestCheck.checkedMessageCount != nil || latestCheck.likelyBillingMessageCount != nil {
                        Divider()
                        HStack(spacing: 16) {
                            if let checkedMessageCount = latestCheck.checkedMessageCount {
                                latestCheckMetric("\(checkedMessageCount) messages checked")
                            }
                            if let likelyBillingMessageCount = latestCheck.likelyBillingMessageCount {
                                latestCheckMetric("\(likelyBillingMessageCount) likely billing")
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(latestCheckAccessibilityLabel(latestCheck))
        }
    }

    private func latestCheckMetric(_ label: String) -> some View {
        Text(label)
            .font(.renewa(12, weight: .semibold))
            .foregroundStyle(RenewaTheme.muted)
    }

    private func latestCheckAccessibilityLabel(_ latestCheck: EmailLatestCheckSummary) -> String {
        var labels = [
            "Latest check",
            latestCheck.inboxLabel,
            "Checked \(latestCheck.completedAt.formatted(.relative(presentation: .named)))",
            latestCheck.outcome,
        ]
        if let checkedMessageCount = latestCheck.checkedMessageCount {
            labels.append("\(checkedMessageCount) messages checked")
        }
        if let likelyBillingMessageCount = latestCheck.likelyBillingMessageCount {
            labels.append("\(likelyBillingMessageCount) likely billing")
        }
        return labels.joined(separator: ". ")
    }

    private var statusIcon: HeroIconName {
        switch presentation.dashboardState {
        case .noInbox: .envelope
        case .scanning: .sparkles
        case .reviewReady, .upToDate: .checkCircle
        case .needsAttention: .exclamationTriangle
        }
    }

    private var statusTint: Color {
        presentation.dashboardState == .needsAttention ? RenewaTheme.coral : RenewaTheme.sage
    }

    private var assistantTitle: String {
        switch presentation.dashboardState {
        case .noInbox: "Connect an inbox"
        case .scanning: "Checking your inbox"
        case .reviewReady: "Your review is ready"
        case .upToDate: "You’re all caught up"
        case .needsAttention: "Your inbox needs attention"
        }
    }

    private var assistantMessage: String {
        switch presentation.dashboardState {
        case .noInbox:
            return "Connect Google or Microsoft with read-only access. You can disconnect it any time."
        case .scanning:
            return "We’ll surface only subscription changes that need your decision."
        case .reviewReady:
            return "Review the changes below when you’re ready."
        case .upToDate:
            return "We’re watching for new subscription changes and will let you know when something needs review."
        case .needsAttention:
            return store.emailScanStatus?.errors.first ?? "Reconnect this inbox to keep monitoring new email."
        }
    }

    private var needsSettingsAction: Bool {
        presentation.dashboardState == .noInbox || presentation.dashboardState == .needsAttention
    }

    private var attentionConnection: EmailConnectionSummary? {
        store.emailScanStatus?.connections.first {
            $0.health == "attention" || $0.monitoringHealth == "reconnect_required"
        }
    }

    private var statusActionTitle: String {
        if presentation.dashboardState == .noInbox { return "Connect inbox" }
        if let connection = attentionConnection { return "Reconnect \(connection.providerTitle)" }
        return "Try again"
    }

    private func performStatusAction() {
        if presentation.dashboardState == .noInbox {
            showingInboxSettings = true
        } else if let connection = attentionConnection {
            Task { await connect(connection.provider) }
        } else {
            Task { _ = await store.startEmailScan() }
        }
    }

    private var inboxSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    connectionSection
                    if presentation.connectionCount > 0 {
                        manualScanSection
                    }
                    NavigationLink {
                        scanDetailsView
                    } label: {
                        settingsDisclosureRow(
                            icon: .rectangleStack,
                            title: "Scan details",
                            detail: "View privacy-safe outcomes and scan history"
                        )
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Opens privacy-safe inbox scan details")

                    if let suppressed = store.emailScanStatus?.suppressedMerchants, !suppressed.isEmpty {
                        suppressionSection(suppressed)
                    }

                    privacyNote
                }
                .padding(24)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
            .background(RenewaTheme.background)
            .navigationTitle("Inbox settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingInboxSettings = false }
                }
            }
        }
    }

    private var manualScanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MANUAL CHECK")
                .font(.renewa(12, weight: .bold))
                .tracking(1)
                .foregroundStyle(RenewaTheme.muted)
            RenewaCard {
                HStack(spacing: 13) {
                    HeroIcon(.arrowPath, size: 21)
                        .foregroundStyle(RenewaTheme.sage)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.isScanning ? "Inbox check in progress" : "Check inbox now")
                            .font(.renewa(15, weight: .semibold))
                            .foregroundStyle(RenewaTheme.ink)
                        Text(
                            presentation.isScanning
                                ? "The current check will continue in the background."
                                : "Use this when you want an immediate update."
                        )
                        .font(.renewa(12))
                        .foregroundStyle(RenewaTheme.muted)
                    }
                    Spacer(minLength: 6)
                    if !presentation.isScanning {
                        Button("Check") {
                            Task { _ = await store.startEmailScan() }
                        }
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.sage)
                        .disabled(!presentation.canStartScan)
                    }
                }
            }
        }
    }

    private var scanDetailsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Scan details")
                        .font(.renewa(25, weight: .bold))
                    Text("Safe outcomes from previous checks. These are not active subscriptions or actions for you.")
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.muted)
                }

                if let items = store.emailScanStatus?.learningSummary?.items, !items.isEmpty {
                    RenewaCard {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    learningItem = item
                                } label: {
                                    HStack(spacing: 12) {
                                        HeroIcon(item.outcome == .ended ? .checkCircle : .lockClosed, size: 19)
                                            .foregroundStyle(item.outcome == .ended ? RenewaTheme.sage : RenewaTheme.muted)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.merchantName)
                                                .font(.renewa(15, weight: .semibold))
                                                .foregroundStyle(RenewaTheme.ink)
                                            Text("\(item.outcome.title) · \(item.receivedAt.formatted(date: .abbreviated, time: .omitted))")
                                                .font(.renewa(12))
                                                .foregroundStyle(RenewaTheme.muted)
                                        }
                                        Spacer()
                                        HeroIcon(.chevronRight, size: 14)
                                            .foregroundStyle(RenewaTheme.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Shows privacy-safe scan details")
                                if index < items.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                } else {
                    RenewaCard {
                        Text("There are no historical outcomes to show yet. Future safe outcomes will appear here without exposing email content.")
                            .font(.renewa(14))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func settingsDisclosureRow(icon: HeroIconName, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            HeroIcon(icon, size: 21)
                .foregroundStyle(RenewaTheme.sage)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.renewa(16, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
                Text(detail)
                    .font(.renewa(12))
                    .foregroundStyle(RenewaTheme.muted)
            }
            Spacer()
            HeroIcon(.chevronRight, size: 16)
                .foregroundStyle(RenewaTheme.muted)
        }
        .padding(18)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(connectedProviders.isEmpty ? "Connect an inbox" : "Connected inboxes")
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

            if connectedProviders.isEmpty {
                Text("Choose Google or Microsoft. Renewa uses read-only access and you can disconnect it at any time.")
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
            }

            ForEach(store.emailScanStatus?.connections ?? []) { connection in
                connectionCard(connection)
            }

            if !connectedProviders.isEmpty {
                inboxAlertSetting
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

    private var inboxAlertSetting: some View {
        RenewaCard {
            Toggle(
                isOn: Binding(
                    get: { store.inboxNotificationSettings.inboxScanOutcomesEnabled },
                    set: { enabled in
                        Task { _ = await store.setInboxScanNotificationsEnabled(enabled) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Inbox scan alerts", systemImage: "bell.badge")
                        .font(.renewa(15, weight: .semibold))
                    Text("Get a private alert when a scan finds subscriptions, finishes with nothing new, or needs you to reconnect.")
                        .font(.renewa(12))
                        .foregroundStyle(RenewaTheme.muted)
                }
            }
            .tint(RenewaTheme.sage)
            .disabled(store.isUpdatingInboxNotifications)
        }
        .accessibilityHint("Controls notifications for completed inbox scans")
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
                        Text(connectionMonitoringLabel(connection, lastChecked: lastScannedAt))
                        .font(.renewa(11, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                    }
                    if let error = connection.monitoringError, connection.monitoringHealth != "active" {
                        Text(error)
                            .font(.renewa(11))
                            .foregroundStyle(RenewaTheme.coral)
                            .lineLimit(2)
                    }
                }

                Spacer()
                if connection.health == "attention" {
                    Button("Reconnect") {
                        Task { await connect(connection.provider) }
                    }
                    .font(.renewa(12, weight: .semibold))
                    .foregroundStyle(RenewaTheme.sage)
                    .disabled(presentation.isScanning)
                } else {
                    Button("Disconnect", role: .destructive) {
                        disconnectTarget = connection
                    }
                    .font(.renewa(12, weight: .semibold))
                    .foregroundStyle(RenewaTheme.coral)
                    .disabled(presentation.isScanning)
                }
            }
        }
    }

    private func connectionMonitoringLabel(
        _ connection: EmailConnectionSummary,
        lastChecked: Date
    ) -> String {
        switch connection.monitoringHealth {
        case "active":
            return "Monitoring new email · checked \(lastChecked.formatted(.relative(presentation: .named)))"
        case "checking":
            return "Checking new inbox activity"
        case "degraded":
            return connection.monitoringFallbackActive == true
                ? "Daily check fallback · checked \(lastChecked.formatted(.relative(presentation: .named)))"
                : "Monitoring needs attention"
        case "reconnect_required":
            return "Reconnect to resume monitoring"
        default:
            return "Checked \(lastChecked.formatted(.relative(presentation: .named)))"
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
                    if EmailDiscoveryPresentationState.canSuppress(candidate) {
                        Button("Not using this") {
                            suppressionCandidate = candidate
                        }
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RenewaTheme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
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
                    }

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

    private func suppressionSection(_ suppressions: [EmailMerchantSuppression]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paused suggestions")
                    .font(.renewa(19, weight: .bold))
                Text("Resume a merchant whenever you want to see it in discovery again.")
                    .font(.renewa(13))
                    .foregroundStyle(RenewaTheme.muted)
            }

            ForEach(suppressions) { merchant in
                RenewaCard {
                    HStack(spacing: 12) {
                        HeroIcon(.rectangleStack, size: 20)
                            .foregroundStyle(RenewaTheme.muted)
                        Text(merchant.merchantTitle)
                            .font(.renewa(15, weight: .semibold))
                        Spacer()
                        Button("Resume") {
                            Task { _ = await store.unsuppressEmailMerchant(merchant) }
                        }
                        .font(.renewa(13, weight: .semibold))
                        .foregroundStyle(RenewaTheme.sage)
                        .disabled(store.isReviewingEmailCandidate)
                    }
                }
            }
        }
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
            Text(
                "Read-only, best-effort inbox evidence. Full content is retrieved only for likely billing mail, processed transiently, and never stored. Missing mail never proves a service is active or ended."
            )
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
                        if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                            store.errorMessage = error.localizedDescription
                        }
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

private struct EmailScanLearningDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: EmailScanLearningItem

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    HeroIcon(item.outcome == .ended ? .checkCircle : .lockClosed, style: .solid, size: 30)
                        .foregroundStyle(item.outcome == .ended ? RenewaTheme.sage : RenewaTheme.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.merchantName)
                            .font(.renewa(23, weight: .bold))
                        Text(item.outcome.title)
                            .font(.renewa(13, weight: .semibold))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                }

                RenewaCard {
                    VStack(alignment: .leading, spacing: 12) {
                        detailRow("Email received", value: item.receivedAt.formatted(date: .long, time: .omitted))
                        detailRow("Billing event", value: item.eventType.capitalized)
                        detailRow("Result", value: item.outcome.title)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Why no action was requested")
                        .font(.renewa(16, weight: .bold))
                    Text(item.explanation)
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.muted)
                }

                Spacer()
                Label("This summary does not include email content or your full inbox address.", systemImage: "lock.fill")
                    .font(.renewa(12, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
            }
            .padding(24)
            .navigationTitle("Scan detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.renewa(13))
                .foregroundStyle(RenewaTheme.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.renewa(13, weight: .semibold))
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct EmailCandidateReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let candidate: EmailSubscriptionCandidate

    @State private var edits: EmailCandidateEdits
    @State private var amountText: String
    @State private var correctionReason = ""

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
                        if let events = candidate.evidenceEvents, !events.isEmpty {
                            Divider()
                            Text("Why we found this")
                                .font(.renewa(14, weight: .bold))
                            ForEach(events) { event in
                                Text("\(event.eventType.capitalized) · \(event.receivedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.renewa(13))
                                    .foregroundStyle(RenewaTheme.muted)
                            }
                        }
                        if let reason = candidate.resolutionReason {
                            Text(reason.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.renewa(12, weight: .medium))
                                .foregroundStyle(RenewaTheme.sage)
                        }
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

                    Picker("Anything to correct?", selection: $correctionReason) {
                        Text("No correction").tag("")
                        Text("Wrong service").tag("wrong_merchant")
                        Text("Wrong amount").tag("wrong_amount")
                        Text("Wrong billing cycle").tag("wrong_cycle")
                        Text("Not a subscription").tag("not_a_subscription")
                        Text("Other").tag("other")
                    }
                    .font(.renewa(14, weight: .medium))

                    Button {
                        Task {
                            let confirmed = await store.reviewEmailCandidate(
                                candidate,
                                decision: .confirm,
                                edits: normalizedEdits,
                                correctionReason: correctionReason.isEmpty ? nil : correctionReason
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
