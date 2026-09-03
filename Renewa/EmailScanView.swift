import AuthenticationServices
import SwiftUI

/// The palette the Inbox mockup is drawn in: a card face a half-step lighter than
/// `RenewaTheme.surface`, plus the borders and placeholder fills that go with it.
/// A confirmation the server flagged as contradicted by stored evidence, held until the user says
/// whether to proceed. Carries the edits so acknowledging re-sends exactly what was submitted.
private struct CandidateWarning: Identifiable {
    let id = UUID()
    let candidate: EmailSubscriptionCandidate
    let edits: EmailCandidateEdits?
    let message: String
}

private enum InboxPalette {
    static let card = Color(red: 0.985, green: 0.974, blue: 0.953)
    static let cardBorder = Color(red: 0.925, green: 0.894, blue: 0.835)
    static let chipFill = Color(red: 0.925, green: 0.894, blue: 0.835)
    static let outline = Color(red: 0.894, green: 0.859, blue: 0.788)
    static let dashed = Color(red: 0.871, green: 0.827, blue: 0.741)
    static let ghost = Color(red: 0.925, green: 0.894, blue: 0.835)
    static let ghostSoft = Color(red: 0.941, green: 0.914, blue: 0.859)
    static let secondaryInk = Color(red: 0.44, green: 0.41, blue: 0.35)
}

struct EmailScanView: View {
    /// The empty state's escape hatch, for people who would rather type a subscription in than
    /// connect a mailbox.
    var onAddManually: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webSession: ASWebAuthenticationSession?
    @State private var appeared = false
    @State private var reviewCandidate: EmailSubscriptionCandidate?
    @State private var suppressionCandidate: EmailSubscriptionCandidate?
    @State private var disconnectTarget: EmailConnectionSummary?
    @State private var learningItem: EmailScanLearningItem?
    @State private var showingClearConfirmation = false
    @State private var showingInboxSettings = false
    @State private var showingScanDetails = false
    @State private var showingInboxMenu = false
    @State private var showingMutedServices = false
    @State private var connectingProvider: String?
    /// Cards the reader has already answered, hidden while the decision is in flight.
    @State private var resolvingCandidateIDs: Set<UUID> = []
    @State private var pendingWarning: CandidateWarning?

    private var presentation: EmailDiscoveryPresentationState {
        EmailDiscoveryPresentationState(status: store.emailScanStatus)
    }

    private var pendingCandidates: [EmailSubscriptionCandidate] {
        (store.emailScanStatus?.candidates ?? [])
            .filter { $0.reviewStatus == .pending && !resolvingCandidateIDs.contains($0.id) }
    }

    private var connectedProviders: Set<String> {
        Set(store.emailScanStatus?.connections.map(\.provider) ?? [])
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .renewaEntrance(appeared, delay: 0.02)
                    if store.isLoadingEmailDiscovery && store.emailScanStatus == nil {
                        inboxLoading
                            .renewaEntrance(appeared, delay: 0.08)
                    } else {
                        inboxDashboard
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
            .background(RenewaTheme.background)

            if showingInboxMenu {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showingInboxMenu = false }
                    .transition(.opacity)

                inboxMenu
                    .padding(.top, 70)
                    .padding(.trailing, 24)
                    .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(RenewaMotion.quick, value: showingInboxMenu)
        .task {
            appeared = true
            #if DEBUG
                if RenewaPreviewFixture.InboxScenario.current == .connect {
                    showingInboxSettings = true
                }
                if RenewaPreviewFixture.InboxScenario.current == .warned,
                    let candidate = store.emailScanStatus?.candidates.first
                {
                    pendingWarning = CandidateWarning(
                        candidate: candidate,
                        edits: EmailCandidateEdits(candidate: candidate),
                        message: "The most recent billing email found for \(candidate.merchantName) was a cancellation."
                    )
                }
            #endif
            async let discovery: Void = store.loadEmailDiscovery()
            async let notificationSettings: Void = store.loadInboxNotificationSettings()
            _ = await (discovery, notificationSettings)
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
                .presentationDetents([.height(inboxSheetHeight), .large])
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
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
        .sheet(isPresented: $showingMutedServices) {
            mutedServicesSheet
                .presentationDetents([.medium])
                .presentationCornerRadius(30)
        }
        // The server no longer decides this on the user's behalf. It says what it found that
        // disagrees; the person looking at their own inbox decides whether that matters.
        .confirmationDialog(
            "Add \(pendingWarning?.candidate.merchantName ?? "this") anyway?",
            isPresented: Binding(
                get: { pendingWarning != nil },
                set: { if !$0 { pendingWarning = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingWarning
        ) { warning in
            Button("Add it anyway") {
                pendingWarning = nil
                resolve(warning.candidate, retryEdits: warning.edits) {
                    await store.reviewEmailCandidate(
                        warning.candidate,
                        decision: .confirm,
                        edits: warning.edits,
                        acknowledgeWarning: true
                    )
                }
            }
            Button("Not now", role: .cancel) { pendingWarning = nil }
        } message: { warning in
            Text(warning.message)
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
                resolve(candidate) {
                    await store.suppressEmailCandidate(candidate) ? .ignored : .notApplied
                }
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
        HStack(spacing: 10) {
            Text("Inbox")
                .font(.renewa(23, weight: .bold))
                .tracking(-0.3)

            Spacer(minLength: 6)

            scanButton

            Button {
                showingInboxMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(InboxPalette.secondaryInk)
                    .frame(width: 34, height: 34)
                    .background(InboxPalette.chipFill, in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Inbox options")
            .accessibilityHint("Shows connection, notification, and privacy options")
        }
    }

    /// The header pill. It carries the one action the screen is about: start a scan, or stop the
    /// one that is running. With no inbox connected it opens the connect sheet instead.
    private var scanButton: some View {
        Button {
            if presentation.isScanning {
                Task { _ = await store.cancelEmailScan() }
            } else if presentation.canStartScan {
                Task { _ = await store.startEmailScan() }
            } else {
                showingInboxSettings = true
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: presentation.isScanning ? "stop.fill" : "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(presentation.isScanning ? RenewaTheme.coral : InboxPalette.secondaryInk)
                Text(presentation.isScanning ? "Stop" : "Scan now")
                    .font(.renewa(13, weight: .semibold))
                    .foregroundStyle(RenewaTheme.ink)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(InboxPalette.chipFill, in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .animation(quickMotion, value: presentation.isScanning)
        .accessibilityLabel(presentation.isScanning ? "Stop inbox scan" : "Scan now")
    }

    private var inboxLoading: some View {
        RenewaDelayedSkeleton(accessibilityLabel: "Loading inbox activity") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    RenewaSkeleton(width: 7, height: 7, cornerRadius: 4)
                    RenewaSkeleton(width: 138, height: 10, cornerRadius: 5)
                }

                RenewaSkeleton(width: 116, height: 30, cornerRadius: 8)
                    .padding(.top, 12)

                RenewaSkeleton(height: 3, cornerRadius: 2)
                    .padding(.top, 14)

                HStack(spacing: 9) {
                    RenewaSkeleton(width: 24, height: 24, cornerRadius: 8)
                    RenewaSkeleton(width: 148, height: 11, cornerRadius: 5)
                }
                .padding(.top, 16)

                RenewaSkeleton(height: 1, cornerRadius: 0.5)
                    .padding(.top, 24)

                RenewaSkeleton(width: 152, height: 12, cornerRadius: 6)
                    .padding(.top, 24)
                RenewaSkeleton(width: 214, height: 10, cornerRadius: 5)
                    .padding(.top, 8)

                VStack(spacing: 10) {
                    RenewaSkeleton(height: 88, cornerRadius: 18)
                    RenewaSkeleton(height: 88, cornerRadius: 18)
                }
                .padding(.top, 16)
            }
        }
        .padding(.top, 20)
    }

    private var inboxDashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            scanOverview
                .padding(.top, 18)
                .renewaEntrance(appeared, delay: 0.06)

            if presentation.dashboardState == .noInbox {
                emptyState
                    .padding(.top, 16)
                    .renewaEntrance(appeared, delay: 0.12)
                    .transition(sectionTransition)
            } else {
                if let attentionMessage {
                    attentionCard(attentionMessage)
                        .padding(.top, 18)
                        .renewaEntrance(appeared, delay: 0.12)
                        .transition(sectionTransition)
                }

                reviewQueue
                    .renewaEntrance(appeared, delay: 0.18)

                trackedSection
                    .padding(.top, 24)
                    .renewaEntrance(appeared, delay: 0.26)

                privacyFooter
                    .padding(.top, 28)
                    .renewaEntrance(appeared, delay: 0.32)
            }
        }
        .animation(sectionMotion, value: pendingCandidates.map(\.id))
        .animation(sectionMotion, value: presentation.isScanning)
        .animation(sectionMotion, value: presentation.dashboardState)
        .animation(sectionMotion, value: presentation.connectionCount)
    }

    // MARK: - Scan overview

    private var scanOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    InboxStatusDot(
                        tint: scanStatusTint,
                        isPulsing: presentation.isScanning,
                        isUrgent: presentation.pendingCount > 0
                    )
                    Text(scanLabel)
                        .font(.renewa(10, weight: .heavy))
                        .textCase(.uppercase)
                        .tracking(1.1)
                        .foregroundStyle(scanLabelTint)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: scanLabel)
                    Spacer(minLength: 0)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(scannedCount)
                        .font(.system(size: 32, weight: .regular, design: .serif))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(quickMotion, value: presentation.scanned)
                    Text(scannedCountLabel)
                        .font(.renewa(11.5, weight: .semibold))
                        .foregroundStyle(RenewaTheme.mutedSoft)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                }
                .padding(.top, 11)

                InboxScanProgressBar(mode: progressMode, reduceMotion: reduceMotion)
                    .padding(.top, 12)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(scanLabel). \(scannedCount) \(scannedCountLabel).")

            accountsRow
                .padding(.top, 14)
        }
    }

    private var accountsRow: some View {
        HStack(spacing: 9) {
            HStack(spacing: -9) {
                if connections.isEmpty {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(InboxPalette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Image(systemName: "envelope")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(RenewaTheme.mutedSoft)
                        }
                } else {
                    ForEach(connections.prefix(3)) { connection in
                        providerBadge(connection.provider)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                    }
                }
            }
            .accessibilityHidden(true)

            Text(accountsLabel)
                .font(.renewa(11.5, weight: .semibold))
                .foregroundStyle(RenewaTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if connectedProviders.count < 2 {
                Button {
                    showingInboxSettings = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .heavy))
                        Text("Add inbox")
                            .font(.renewa(10.5, weight: .bold))
                    }
                    .foregroundStyle(RenewaTheme.mutedSoft)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay {
                        Capsule().stroke(InboxPalette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityHint("Connect another Google or Microsoft inbox")
            }
        }
    }

    private func providerBadge(_ provider: String) -> some View {
        inboxProviderIcon(provider, size: 16)
            .frame(width: 24, height: 24)
            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(InboxPalette.cardBorder, lineWidth: 1)
            }
            .padding(2)
            .background(RenewaTheme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            sectionDivider
                .padding(.bottom, 34)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(InboxPalette.dashed, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: "envelope")
                        .font(.system(size: 21, weight: .light))
                        .foregroundStyle(Color(red: 0.714, green: 0.675, blue: 0.600))
                }
                .accessibilityHidden(true)

            Text("Nothing to read yet.")
                .font(.system(size: 24, weight: .regular, design: .serif))
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            Text("Connect a mailbox and the receipts already sitting there become your subscription list. It usually takes under a minute.")
                .font(.renewa(12.5, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 258)
                .padding(.top, 9)

            Button {
                showingInboxSettings = true
            } label: {
                Text("Connect a mailbox")
                    .font(.renewa(13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .frame(height: 46)
                    .background(RenewaTheme.sage, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 22)

            Button {
                onAddManually()
            } label: {
                Text("Add a subscription by hand")
                    .font(.renewa(12, weight: .bold))
                    .foregroundStyle(RenewaTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .buttonStyle(PressScaleStyle())
            .padding(.top, 12)

            Text(privacyLine)
                .font(.renewa(11, weight: .medium))
                .foregroundStyle(RenewaTheme.mutedSoft)
                .multilineTextAlignment(.center)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 252)
                .padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Needs attention

    private func attentionCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(RenewaTheme.clay)
                .frame(width: 18, height: 18)
                .background(RenewaTheme.clayTint, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(attentionTitle)
                    .font(.renewa(12.5, weight: .bold))
                Text(message)
                    .font(.renewa(11.5, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(reconnectTarget == nil ? "Try again" : "Reconnect") {
                if let connection = reconnectTarget {
                    Task { await connect(connection.provider) }
                } else {
                    Task { _ = await store.startEmailScan() }
                }
            }
            .font(.renewa(12, weight: .bold))
            .foregroundStyle(RenewaTheme.sage)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(connectingProvider != nil || presentation.isScanning)
        }
        .padding(13)
        .background(InboxPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InboxPalette.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Review queue

    /// The mockup's "Found in your inbox" block: cards when something needs a yes, placeholders
    /// while the scan is still reading, and one settled line when there is nothing left.
    @ViewBuilder private var reviewQueue: some View {
        if !pendingCandidates.isEmpty {
            pendingQueue
                .padding(.top, 22)
                .transition(sectionTransition)
        } else if presentation.isScanning {
            searchingQueue
                .padding(.top, 22)
                .transition(sectionTransition)
        } else {
            settledQueue
                .padding(.top, 22)
                .transition(sectionTransition)
        }
    }

    private var pendingQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Found in your inbox")
                    .font(.renewa(13.5, weight: .bold))
                Spacer(minLength: 8)
                Text("\(pendingCandidates.count) to review")
                    .font(.renewa(11.5, weight: .semibold))
                    .foregroundStyle(RenewaTheme.mutedSoft)
                    .contentTransition(.numericText())
            }
            .padding(.top, 22)

            Text("Nothing is added to your list until you say so.")
                .font(.renewa(11.5, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            VStack(spacing: 10) {
                ForEach(pendingCandidates) { candidate in
                    pendingCard(candidate)
                        .transition(cardTransition)
                }
            }
            .padding(.top, 14)
        }
    }

    private func pendingCard(_ candidate: EmailSubscriptionCandidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(candidate.merchantName)
                    .font(.renewa(13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let amount = candidate.amount, let currency = candidate.currency {
                    Text(amount.currencyText(code: currency))
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .lineLimit(1)
                } else {
                    // A receipt with no amount would set a whole sentence in the price slot.
                    Text("Amount to add")
                        .font(.renewa(10.5, weight: .bold))
                        .foregroundStyle(RenewaTheme.clay)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RenewaTheme.clayTint, in: Capsule())
                        .fixedSize()
                }
            }

            Text(candidate.evidence)
                .font(.renewa(11, weight: .medium))
                .foregroundStyle(RenewaTheme.mutedSoft)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 8) {
                Button {
                    track(candidate)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: needsReviewSheet(candidate) ? "chevron.right" : "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                        Text(needsReviewSheet(candidate) ? "Review" : "Track it")
                    }
                    .font(.renewa(12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RenewaTheme.sage, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())

                Button {
                    dismissCandidate(candidate)
                } label: {
                    Text(candidate.suggestedAction == .cancel ? "Keep it" : "Not one")
                        .font(.renewa(12, weight: .semibold))
                        .foregroundStyle(InboxPalette.secondaryInk)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(InboxPalette.outline, lineWidth: 1)
                        }
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.top, 12)
        }
        .padding(14)
        .background(InboxPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InboxPalette.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var searchingQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Found in your inbox")
                    .font(.renewa(13.5, weight: .bold))
                Spacer(minLength: 8)
                Text("still reading")
                    .font(.renewa(11.5, weight: .semibold))
                    .foregroundStyle(RenewaTheme.mutedSoft)
            }
            .padding(.top, 22)

            Text("Anything that looks like a subscription appears here for you to confirm.")
                .font(.renewa(11.5, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            VStack(spacing: 10) {
                InboxGhostCard(titleWidth: 104, metaWidth: 168, delay: 0)
                InboxGhostCard(titleWidth: 82, metaWidth: 132, delay: 0.35)
            }
            .padding(.top, 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Still reading your inbox. Anything it finds will appear here.")
    }

    private var settledQueue: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionDivider

            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(RenewaTheme.sage)
                    .frame(width: 18, height: 18)
                    .background(RenewaTheme.sageTint, in: Circle())
                    .accessibilityHidden(true)
                Text(hasFinishedScan ? "Nothing left to review" : "Nothing to review yet")
                    .font(.renewa(12.5, weight: .semibold))
                    .foregroundStyle(InboxPalette.secondaryInk)
                Spacer(minLength: 0)
            }
            .padding(.top, 20)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Tracked automatically

    @ViewBuilder private var trackedSection: some View {
        let activities = store.emailScanStatus?.recentActivity ?? []
        let learningItems = store.emailScanStatus?.learningSummary?.items ?? []

        if !activities.isEmpty || !learningItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionDivider

                HStack(alignment: .firstTextBaseline) {
                    Text("Tracked automatically")
                        .font(.renewa(13.5, weight: .bold))
                    Spacer(minLength: 8)
                    Button("See all") {
                        showingScanDetails = true
                    }
                    .font(.renewa(11.5, weight: .semibold))
                    .foregroundStyle(RenewaTheme.mutedSoft)
                }
                .padding(.top, 22)

                Text("Every receipt it recognises is added without asking.")
                    .font(.renewa(11.5, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                    .padding(.top, 3)

                VStack(spacing: 17) {
                    ForEach(activities) { activity in
                        trackedActivityRow(activity)
                    }
                    ForEach(learningItems.prefix(4)) { item in
                        Button {
                            learningItem = item
                        } label: {
                            trackedLearningRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    private func trackedActivityRow(_ activity: EmailScanActivity) -> some View {
        let isCancel = activity.outcome == "canceled"
        let isNew = activity.outcome == "confirmed" && activity.createdAt > Date().addingTimeInterval(-3600)
        return HStack(alignment: .top, spacing: 11) {
            trackedIcon(
                system: isCancel ? "minus" : "checkmark",
                tint: isCancel ? RenewaTheme.muted : RenewaTheme.sage
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(activity.title)
                        .font(.renewa(12.5, weight: .semibold))
                        .lineLimit(2)
                    if isNew {
                        Text("NEW")
                            .font(.renewa(9.5, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(RenewaTheme.positive)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RenewaTheme.sageTint, in: Capsule())
                    }
                }
                Text(activity.detail)
                    .font(.renewa(11.5, weight: .medium))
                    .foregroundStyle(RenewaTheme.mutedSoft)
            }
            Spacer(minLength: 6)
            if let amount = activity.amount, let currency = activity.currency {
                Text(amount.currencyText(code: currency))
                    .font(.system(size: 14, weight: .regular, design: .serif))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func trackedLearningRow(_ item: EmailScanLearningItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            trackedIcon(
                system: item.outcome == .ended ? "checkmark" : "questionmark",
                tint: item.outcome == .ended ? RenewaTheme.sage : RenewaTheme.muted
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.outcome == .ended ? "No action needed for \(item.merchantName)" : "Need more evidence for \(item.merchantName)")
                    .font(.renewa(12.5, weight: .semibold))
                    .multilineTextAlignment(.leading)
                Text(item.receivedAt.formatted(.relative(presentation: .named)))
                    .font(.renewa(11.5, weight: .medium))
                    .foregroundStyle(RenewaTheme.mutedSoft)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.79, green: 0.75, blue: 0.66))
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackedIcon(system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .background(tint.opacity(0.16), in: Circle())
            .padding(.top, 1)
            .accessibilityHidden(true)
    }

    private var privacyFooter: some View {
        Text(privacyLine)
            .font(.renewa(11, weight: .medium))
            .foregroundStyle(RenewaTheme.mutedSoft)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(RenewaTheme.hairline)
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: - Decisions

    /// A candidate can be tracked in one tap once every field the confirmation needs is already
    /// there. Anything missing or ambiguous opens the review sheet instead.
    private func needsReviewSheet(_ candidate: EmailSubscriptionCandidate) -> Bool {
        if candidate.suggestedAction == .cancel || candidate.eventType == "canceled" { return true }
        if !candidate.validationIssues.isEmpty { return true }
        return !EmailDiscoveryPresentationState.confirmationIssues(
            for: candidate,
            edits: EmailCandidateEdits(candidate: candidate)
        ).isEmpty
    }

    private func track(_ candidate: EmailSubscriptionCandidate) {
        guard !needsReviewSheet(candidate) else {
            reviewCandidate = candidate
            return
        }
        let edits = EmailCandidateEdits(candidate: candidate)
        resolve(candidate, retryEdits: edits) {
            await store.reviewEmailCandidate(candidate, decision: .confirm, edits: edits)
        }
    }

    private func dismissCandidate(_ candidate: EmailSubscriptionCandidate) {
        guard !EmailDiscoveryPresentationState.canSuppress(candidate) else {
            suppressionCandidate = candidate
            return
        }
        resolve(candidate) {
            await store.reviewEmailCandidate(candidate, decision: .ignore)
        }
    }

    /// Collapses the card as soon as it is answered, and puts it back unless the decision actually
    /// settled. A warning or a failure both leave the card exactly where it was, because in both
    /// cases nothing changed on the server — collapsing anyway is how a discovery went missing
    /// without anyone noticing.
    private func resolve(
        _ candidate: EmailSubscriptionCandidate,
        retryEdits: EmailCandidateEdits? = nil,
        _ decide: @escaping () async -> EmailCandidateOutcome
    ) {
        withAnimation(sectionMotion) { _ = resolvingCandidateIDs.insert(candidate.id) }
        Task {
            let outcome = await decide()
            if outcome.settlesCard {
                resolvingCandidateIDs.remove(candidate.id)
            } else {
                withAnimation(sectionMotion) { _ = resolvingCandidateIDs.remove(candidate.id) }
            }
            if let warning = outcome.warning {
                pendingWarning = CandidateWarning(
                    candidate: candidate,
                    edits: retryEdits,
                    message: warning.message
                )
            } else if outcome == .notApplied, store.errorMessage == nil {
                // A thrown request already reported itself through `errorMessage`; this covers the
                // other shape — the server answered, but not with anything that applied.
                store.errorMessage = "\(candidate.merchantName) was not added. Please try again."
            }
        }
    }

    // MARK: - Copy and motion

    private var connections: [EmailConnectionSummary] {
        store.emailScanStatus?.connections ?? []
    }

    private var hasFinishedScan: Bool {
        !presentation.isScanning && (presentation.scanned > 0 || presentation.lastScannedAt != nil)
    }

    private var progressMode: InboxScanProgressBar.Mode {
        if presentation.isScanning { return .scanning }
        switch presentation.dashboardState {
        case .needsAttention, .scanFailed: return .interrupted
        default: return hasFinishedScan ? .finished : .idle
        }
    }

    private var scannedCount: String {
        presentation.dashboardState == .noInbox ? "0" : presentation.scanned.formatted(.number)
    }

    private var scannedCountLabel: String {
        if presentation.isScanning { return "emails read so far" }
        if hasFinishedScan { return "emails read in the last scan" }
        return "emails read"
    }

    /// Sentence case: the hero sets it in caps, VoiceOver reads it as written.
    private var scanLabel: String {
        switch presentation.dashboardState {
        case .noInbox:
            return "No inbox connected"
        case .scanning:
            return presentation.stageTitle
        case .needsAttention:
            return "Needs attention"
        case .scanFailed:
            return "Couldn’t finish the scan"
        case .reviewReady:
            return "Ready for your review"
        case .upToDate:
            return presentation.isMonitoringAutomatically
                ? "Watching your inbox" : "Inbox is up to date"
        }
    }

    private var scanStatusTint: Color {
        switch presentation.dashboardState {
        case .needsAttention, .scanFailed: RenewaTheme.clay
        case .noInbox: Color(red: 0.765, green: 0.733, blue: 0.659)
        default: RenewaTheme.sage
        }
    }

    private var scanLabelTint: Color {
        switch presentation.dashboardState {
        case .needsAttention, .scanFailed: RenewaTheme.clay
        case .noInbox: RenewaTheme.mutedSoft
        default: RenewaTheme.sage
        }
    }

    private var accountsLabel: String {
        switch connections.count {
        case 0: "Nothing being watched"
        case 1: connections[0].redactedEmail ?? connections[0].providerTitle
        default: "\(connections.count) inboxes"
        }
    }

    /// Only a connection problem offers "Reconnect"; a scan that failed for any other reason
    /// offers "Try again" instead.
    private var reconnectTarget: EmailConnectionSummary? {
        guard presentation.dashboardState == .needsAttention else { return nil }
        return connections.first {
            $0.health == "attention" || $0.monitoringHealth == "reconnect_required"
        }
    }

    private var attentionTitle: String {
        presentation.dashboardState == .scanFailed
            ? "Couldn’t finish the scan" : "An inbox needs attention"
    }

    private var attentionMessage: String? {
        switch presentation.dashboardState {
        case .needsAttention:
            if let connection = reconnectTarget {
                return connection.monitoringError
                    ?? "Reconnect \(connection.providerTitle) to keep reading new billing mail."
            }
            return store.emailScanStatus?.errors.first
                ?? "Reconnect your inbox to keep reading new billing mail."
        case .scanFailed:
            return store.emailScanStatus?.errors.first
                ?? "Something interrupted this scan. You can try again."
        default:
            return nil
        }
    }

    private var privacyLine: String {
        "Only receipts and likely billing mail are read. Email content is processed transiently and is never stored by Renewa."
    }

    private var sectionMotion: Animation? {
        reduceMotion ? .easeOut(duration: 0.14) : RenewaMotion.standard
    }

    private var quickMotion: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.quick
    }

    private var sectionTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private var cardTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity
                    .combined(with: .move(edge: .top))
                    .combined(with: .scale(scale: 0.97, anchor: .top)),
                removal: .opacity
                    .combined(with: .move(edge: .trailing))
                    .combined(with: .scale(scale: 0.96, anchor: .top))
            )
    }

    private var inboxMenu: some View {
        VStack(spacing: 0) {
            inboxMenuRow(
                icon: "envelope",
                title: "Manage inboxes",
                detail: "\(presentation.connectionCount)"
            ) {
                showingInboxMenu = false
                showingInboxSettings = true
            }

            inboxMenuToggleRow(
                icon: "bell",
                title: "Inbox scan alerts",
                isOn: store.inboxNotificationSettings.inboxScanOutcomesEnabled
            ) {
                Task {
                    _ = await store.setInboxScanNotificationsEnabled(
                        !store.inboxNotificationSettings.inboxScanOutcomesEnabled
                    )
                }
            }
            .disabled(store.isUpdatingInboxNotifications)

            menuDivider

            inboxMenuRow(
                icon: "bell.slash",
                title: "Muted services",
                detail: "\(store.emailScanStatus?.suppressedMerchants.count ?? 0)"
            ) {
                showingInboxMenu = false
                showingMutedServices = true
            }

            inboxMenuRow(icon: "clock", title: "Everything it found") {
                showingInboxMenu = false
                showingScanDetails = true
            }

            inboxMenuRow(icon: "trash", title: "Clear scan history") {
                showingInboxMenu = false
                showingClearConfirmation = true
            }
            .disabled(store.emailScanStatus?.scanID == nil)
        }
        .padding(7)
        .frame(width: 260)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(RenewaTheme.divider.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: RenewaTheme.ink.opacity(0.23), radius: 20, y: 9)
        .accessibilityElement(children: .contain)
    }

    private var menuDivider: some View {
        Divider()
            .overlay(Color(red: 0.94, green: 0.91, blue: 0.85))
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
    }

    private func inboxMenuRow(
        icon: String,
        title: String,
        detail: String? = nil,
        isEnabled: Bool? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.renewa(13, weight: .semibold))
                Spacer(minLength: 6)
                if let isEnabled {
                    Text(isEnabled ? "On" : "Off")
                        .font(.renewa(11, weight: .semibold))
                        .foregroundStyle(isEnabled ? RenewaTheme.sage : RenewaTheme.muted)
                } else if let detail {
                    Text(detail)
                        .font(.renewa(11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.66, green: 0.62, blue: 0.54))
                }
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(.horizontal, 11)
            .frame(height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(InboxMenuButtonStyle())
    }

    private func inboxMenuToggleRow(
        icon: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.renewa(13, weight: .semibold))
                Spacer(minLength: 6)
                InboxToggle(isOn: isOn)
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(.horizontal, 11)
            .frame(height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(InboxMenuButtonStyle())
        .accessibilityValue(isOn ? "On" : "Off")
    }

    /// Keeps the connect sheet at the mockup's bottom-sheet height instead of a full page. It
    /// grows with the rows it has to show, and `.large` stays available for long lists.
    private var inboxSheetHeight: CGFloat {
        let rows = connections.count + max(2 - connectedProviders.count, 0)
        return 140 + CGFloat(max(rows, 1)) * 78
    }

    private var inboxSettingsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(connectedProviders.isEmpty ? "Add an inbox" : "Your inboxes")
                    .font(.renewa(17, weight: .bold))
                Text("Watching more accounts catches subscriptions billed to work or personal mail.")
                    .font(.renewa(11.5, weight: .medium))
                    .foregroundStyle(RenewaTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)

                VStack(spacing: 10) {
                    ForEach(connections) { connection in
                        inboxConnectionRow(connection)
                            .transition(sectionTransition)
                    }

                    if !connectedProviders.contains("google") {
                        inboxProviderRow(
                            title: "Google Gmail",
                            detail: "Personal and work Google accounts",
                            provider: "google"
                        )
                    }

                    if !connectedProviders.contains("microsoft") {
                        inboxProviderRow(
                            title: "Microsoft Outlook",
                            detail: "Work and personal Microsoft accounts",
                            provider: "microsoft"
                        )
                    }
                }
                .padding(.top, 18)
                .animation(sectionMotion, value: connections.count)
                .animation(quickMotion, value: connectingProvider)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.top, 1)
                    Text("Read-only access to likely billing mail. You can disconnect any inbox at any time.")
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.renewa(11, weight: .medium))
                .foregroundStyle(RenewaTheme.mutedSoft)
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(RenewaTheme.background)
    }

    private var mutedServicesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Muted services")
                        .font(.renewa(21, weight: .bold))
                    Text("Muted services won’t be suggested from inbox evidence. You can restore them any time.")
                        .font(.renewa(12, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)

                    if let suppressed = store.emailScanStatus?.suppressedMerchants, !suppressed.isEmpty {
                        suppressionSection(suppressed)
                    } else {
                        Text("No services are muted.")
                            .font(.renewa(13, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                            .padding(.top, 4)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(RenewaTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingMutedServices = false }
                }
            }
        }
    }

    private func inboxConnectionRow(_ connection: EmailConnectionSummary) -> some View {
        let needsReconnect =
            connection.health == "attention" || connection.monitoringHealth == "reconnect_required"
        return Button {
            if needsReconnect {
                Task { await connect(connection.provider) }
            } else {
                disconnectTarget = connection
            }
        } label: {
            HStack(spacing: 12) {
                inboxProviderIcon(connection.provider, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.providerTitle)
                        .font(.renewa(13.5, weight: .semibold))
                    Text(
                        needsReconnect
                            ? "Reconnect to keep reading new mail"
                            : (connection.redactedEmail ?? "Connected inbox")
                    )
                    .font(.renewa(11.5, weight: .medium))
                    .foregroundStyle(needsReconnect ? RenewaTheme.clay : RenewaTheme.muted)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if connectingProvider == connection.provider {
                    ProgressView().tint(RenewaTheme.sage)
                } else if needsReconnect {
                    Text("Reconnect")
                        .font(.renewa(12, weight: .bold))
                        .foregroundStyle(RenewaTheme.sage)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RenewaTheme.sage, in: Circle())
                }
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(.horizontal, 15)
            .frame(minHeight: 68)
            .frame(maxWidth: .infinity)
            .background(InboxPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(InboxPalette.cardBorder, lineWidth: 1)
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(connectingProvider != nil)
        .accessibilityHint(
            needsReconnect ? "Reconnects this inbox" : "Opens the option to disconnect this inbox"
        )
    }

    private func inboxProviderRow(
        title: String,
        detail: String,
        provider: String
    ) -> some View {
        Button {
            Task { await connect(provider) }
        } label: {
            HStack(spacing: 12) {
                inboxProviderIcon(provider, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.renewa(13.5, weight: .semibold))
                    Text(connectingProvider == provider ? "Opening secure sign-in…" : detail)
                        .font(.renewa(11.5, weight: .medium))
                        .foregroundStyle(RenewaTheme.muted)
                }
                Spacer(minLength: 8)
                if connectingProvider == provider {
                    ProgressView()
                        .tint(RenewaTheme.sage)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.79, green: 0.75, blue: 0.66))
                }
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(.horizontal, 15)
            .frame(minHeight: 68)
            .frame(maxWidth: .infinity)
            .background(InboxPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(InboxPalette.cardBorder, lineWidth: 1)
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(connectingProvider != nil)
    }

    private func inboxProviderIcon(_ provider: String, size: CGFloat) -> some View {
        Image(provider == "google" ? "Gmail" : "Outlook")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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

    private func connect(_ provider: String) async {
        connectingProvider = provider
        do {
            let url = try await store.emailAuthorizationURL(provider: provider)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "renewa") { callbackURL, error in
                Task { @MainActor in
                    defer { connectingProvider = nil }
                    if let error {
                        if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                            store.errorMessage = "Couldn’t connect this inbox: \(error.localizedDescription)"
                        }
                    } else if let callbackURL {
                        let result = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
                        let callbackError = result?.queryItems?.first(where: { $0.name == "error" })?.value
                        if let callbackError, !callbackError.isEmpty {
                            store.errorMessage = "Couldn’t connect this inbox: \(callbackError)"
                        } else {
                            // Hand the reader straight back to the scan they just authorised.
                            showingInboxSettings = false
                            await store.loadEmailDiscovery()
                            _ = await store.startEmailScan()
                        }
                    }
                    webSession = nil
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = OAuthPresentationContext.shared
            webSession = session
            if !session.start() {
                webSession = nil
                connectingProvider = nil
                store.errorMessage = "Couldn’t open secure sign-in. Please try again."
            }
        } catch {
            connectingProvider = nil
            store.errorMessage = error.localizedDescription
        }
    }

}

/// The status dot, with the halo that pushes out of it while a scan is running.
private struct InboxStatusDot: View {
    let tint: Color
    let isPulsing: Bool
    /// A faster pulse once there is something waiting to be reviewed.
    let isUrgent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .overlay {
                if isPulsing {
                    Circle()
                        .stroke(tint.opacity(0.42), lineWidth: 4)
                        .scaleEffect(pulse ? 2.2 : 1)
                        .opacity(pulse ? 0 : 0.85)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: isUrgent ? 1.1 : 1.6)
                                    .repeatForever(autoreverses: false),
                            value: pulse
                        )
                        .task(id: reduceMotion) {
                            pulse = false
                            guard !reduceMotion else { return }
                            try? await Task.sleep(for: .milliseconds(60))
                            guard !Task.isCancelled else { return }
                            pulse = true
                        }
                }
            }
            .accessibilityHidden(true)
    }
}

/// The hero's progress line. The scan API reports how many messages it has read but never a
/// total, so a running scan gets an indeterminate segment rather than a percentage.
private struct InboxScanProgressBar: View {
    enum Mode {
        /// Nothing has been read yet — an empty track.
        case idle
        /// A scan is running: an indeterminate segment travels the track.
        case scanning
        /// A scan finished cleanly: the track fills.
        case finished
        /// A scan stopped partway, so the track stops partway too.
        case interrupted
    }

    let mode: Mode
    let reduceMotion: Bool

    @State private var slide = false
    @State private var filled = false

    var body: some View {
        GeometryReader { proxy in
            let segment = max(proxy.size.width * 0.32, 44)
            ZStack(alignment: .leading) {
                Capsule().fill(RenewaTheme.track)

                switch mode {
                case .idle:
                    EmptyView()
                case .scanning:
                    Capsule()
                        .fill(RenewaTheme.sage)
                        .frame(width: reduceMotion ? proxy.size.width * 0.4 : segment)
                        .offset(x: reduceMotion ? 0 : (slide ? proxy.size.width : -segment))
                        .animation(
                            reduceMotion
                                ? nil
                                : .linear(duration: 1.45).repeatForever(autoreverses: false),
                            value: slide
                        )
                        // Flipping the flag one frame late is what lets the animation attach;
                        // set in the same frame as insertion it snaps straight to the end.
                        .task(id: reduceMotion) {
                            slide = false
                            guard !reduceMotion else { return }
                            try? await Task.sleep(for: .milliseconds(60))
                            guard !Task.isCancelled else { return }
                            slide = true
                        }
                case .finished, .interrupted:
                    Capsule()
                        .fill(mode == .finished ? RenewaTheme.sage : RenewaTheme.clay)
                        .frame(
                            width: filled ? proxy.size.width * (mode == .finished ? 1 : 0.42) : 0
                        )
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.55),
                            value: filled
                        )
                        .task(id: reduceMotion) {
                            filled = false
                            try? await Task.sleep(for: .milliseconds(60))
                            guard !Task.isCancelled else { return }
                            filled = true
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Placeholder card shown while a scan is still reading and has nothing to confirm yet. It
/// breathes rather than shimmers, so it reads as waiting instead of loading.
private struct InboxGhostCard: View {
    let titleWidth: CGFloat
    let metaWidth: CGFloat
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                bar(width: titleWidth, height: 9, tint: InboxPalette.ghost)
                Spacer(minLength: 8)
                bar(width: 34, height: 9, tint: InboxPalette.ghost)
            }
            bar(width: metaWidth, height: 8, tint: InboxPalette.ghostSoft)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(InboxPalette.outline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .opacity(breathing ? 0.55 : 1)
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 0.95).repeatForever(autoreverses: true).delay(delay),
            value: breathing
        )
        .task(id: reduceMotion) {
            breathing = false
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            breathing = true
        }
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat, tint: Color) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: width, height: height)
    }
}

private struct InboxMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color(red: 0.94, green: 0.91, blue: 0.85)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct InboxToggle: View {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(isOn ? RenewaTheme.sage : Color(red: 0.87, green: 0.83, blue: 0.74))
            .frame(width: 32, height: 19)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 15, height: 15)
                    .padding(2)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            .animation(reduceMotion ? nil : RenewaMotion.quick, value: isOn)
            .accessibilityHidden(true)
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

/// Reviewing a discovery uses the same form as adding a subscription by hand — the agent only
/// pre-fills it. The evidence sits in the header so the user can see what the values came from, and
/// the correction picker follows the fields it is asking about.
private struct EmailCandidateReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let candidate: EmailSubscriptionCandidate

    @State private var draft: SubscriptionDraft
    @State private var correctionReason = ""
    @State private var warningMessage: String?
    @FocusState private var focusedField: SubscriptionFormField?

    init(candidate: EmailSubscriptionCandidate) {
        self.candidate = candidate
        _draft = State(initialValue: SubscriptionDraft(candidate: candidate))
    }

    private var isCancellation: Bool {
        candidate.eventType == "canceled"
    }

    private var issues: [String] {
        EmailDiscoveryPresentationState.confirmationIssues(for: candidate, edits: draft.candidateEdits)
    }

    var body: some View {
        NavigationStack {
            SubscriptionFormView(
                draft: $draft,
                focusedField: $focusedField,
                showsBillingFields: !isCancellation,
                currencyIsEditable: true,
                validationMessage: issues.isEmpty ? nil : issues.joined(separator: " "),
                header: { evidenceHeader },
                footer: { correctionPicker }
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.renewa(14, weight: .semibold))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                confirmButton
            }
            .confirmationDialog(
                "Add \(candidate.merchantName) anyway?",
                isPresented: Binding(
                    get: { warningMessage != nil },
                    set: { if !$0 { warningMessage = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Add it anyway") {
                    warningMessage = nil
                    Task { await confirm(acknowledging: true) }
                }
                Button("Not now", role: .cancel) { warningMessage = nil }
            } message: {
                Text(warningMessage ?? "")
            }
        }
    }

    private var evidenceHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            SubscriptionFormHeader(
                title: candidate.suggestedAction.title,
                subtitle: candidate.evidence
            )
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
    }

    private var correctionPicker: some View {
        Picker("Anything to correct?", selection: $correctionReason) {
            Text("No correction").tag("")
            Text("Wrong service").tag("wrong_merchant")
            Text("Wrong amount").tag("wrong_amount")
            Text("Wrong billing cycle").tag("wrong_cycle")
            Text("Not a subscription").tag("not_a_subscription")
            Text("Other").tag("other")
        }
        .font(.renewa(14, weight: .medium))
    }

    private var confirmButton: some View {
        Button {
            focusedField = nil
            Task { await confirm() }
        } label: {
            RenewaPrimaryActionLabel(
                title: isCancellation ? "Confirm cancellation" : "Confirm discovery",
                pendingTitle: "Applying confirmed change…",
                isPending: store.emailCandidatePendingID == candidate.id,
                icon: .checkCircle
            )
            .font(.renewa(17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 57)
            .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!issues.isEmpty || store.isReviewingEmailCandidate)
        .opacity(issues.isEmpty ? 1 : 0.48)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    /// Only dismisses once the confirmation actually applied. A warning keeps the sheet open with
    /// the user's edits intact, so proceeding re-sends exactly what they typed rather than making
    /// them fill the form in again.
    private func confirm(acknowledging: Bool = false) async {
        let outcome = await store.reviewEmailCandidate(
            candidate,
            decision: .confirm,
            edits: draft.candidateEdits,
            correctionReason: correctionReason.isEmpty ? nil : correctionReason,
            acknowledgeWarning: acknowledging
        )
        if let warning = outcome.warning {
            warningMessage = warning.message
        } else if outcome.didApply {
            dismiss()
        }
    }
}

#if DEBUG
    private func inboxPreviewStore(_ scenario: RenewaPreviewFixture.InboxScenario) -> AppStore {
        let store = RenewaPreviewFixture.store()
        store.emailScanStatus = RenewaPreviewFixture.emailScanStatus(scenario)
        store.isLoadingEmailDiscovery = scenario == .loading
        return store
    }

    #Preview("Inbox · empty") {
        EmailScanView().environment(inboxPreviewStore(.empty))
    }

    #Preview("Inbox · scanning") {
        EmailScanView().environment(inboxPreviewStore(.scanning))
    }

    #Preview("Inbox · review ready") {
        EmailScanView().environment(inboxPreviewStore(.reviewReady))
    }

    #Preview("Inbox · all clear") {
        EmailScanView().environment(inboxPreviewStore(.clear))
    }

    #Preview("Inbox · scan failed") {
        EmailScanView().environment(inboxPreviewStore(.failed))
    }

    #Preview("Inbox · reconnect") {
        EmailScanView().environment(inboxPreviewStore(.reconnect))
    }

    #Preview("Inbox · loading") {
        EmailScanView().environment(inboxPreviewStore(.loading))
    }

    #Preview("Inbox · warned") {
        EmailScanView().environment(inboxPreviewStore(.warned))
    }

    #Preview("Inbox · review sheet") {
        EmailCandidateReviewSheet(
            candidate: RenewaPreviewFixture.inboxCandidate(
                "Figma Professional",
                amount: 15,
                evidence: "Receipt from figma.com · 4 minutes ago"
            )
        )
        .environment(inboxPreviewStore(.reviewReady))
    }

    #Preview("Inbox · review sheet · needs an amount") {
        EmailCandidateReviewSheet(
            candidate: RenewaPreviewFixture.inboxCandidate(
                "Adobe Creative Cloud",
                amount: nil,
                evidence: "Order confirmation, no renewal date named · Aug 20",
                action: .review,
                validationIssues: ["missing_amount"]
            )
        )
        .environment(inboxPreviewStore(.reviewReady))
    }
#endif
