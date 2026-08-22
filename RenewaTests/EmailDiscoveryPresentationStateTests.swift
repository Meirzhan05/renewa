import XCTest
@testable import Renewa

final class EmailDiscoveryPresentationStateTests: XCTestCase {
    @MainActor
    func test_idleWithoutConnections_promptsConnection() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(status: .idle, connectionCount: 0)
        )

        XCTAssertEqual(state.headline, "Connect an inbox")
        XCTAssertFalse(state.canStartScan)
    }

    @MainActor
    func test_extractingScan_reportsBoundedProgress() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(
                status: .running,
                stage: .extracting,
                connectionCount: 2,
                scanned: 80,
                candidateMessages: 6
            )
        )

        XCTAssertTrue(state.isScanning)
        XCTAssertEqual(state.dashboardState, .scanning)
        XCTAssertEqual(state.headline, "Checking subscription evidence")
        XCTAssertEqual(state.progressText, "80 messages checked · 6 likely billing emails")
    }

    @MainActor
    func test_completedScan_withPendingCandidates_requestsReview() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(status: .completed, pendingCount: 2)
        )

        XCTAssertEqual(state.headline, "Changes are ready for review")
        XCTAssertEqual(state.progressText, "2 discoveries waiting for confirmation.")
    }

    @MainActor
    func test_partialScan_preservesConnectionIssueMessaging() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(status: .partial, errors: ["Microsoft mail could not be read."])
        )

        XCTAssertEqual(state.headline, "An inbox needs attention")
        XCTAssertEqual(state.progressText, "Completed with 1 connection issue.")
    }

    @MainActor
    func test_completedScanWithoutCandidates_staysUpToDateWithoutReview() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(
                status: .completed,
                learningSummary: EmailScanLearningSummary(
                    endedCount: 1,
                    uncertainCount: 2,
                    items: []
                )
            )
        )

        XCTAssertEqual(state.dashboardState, .upToDate)
        XCTAssertEqual(state.pendingCount, 0)
        XCTAssertEqual(state.headline, "Daily checks are active")
        XCTAssertEqual(state.progressText, "Daily reconciliation is active while live inbox monitoring needs attention.")
    }

    @MainActor
    func test_queuedScan_isPresentedAsScanningBeforeMessagesAreAvailable() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(
                status: .queued,
                stage: .queued,
                connectionCount: 1
            )
        )

        XCTAssertTrue(state.isScanning)
        XCTAssertEqual(state.dashboardState, .scanning)
        XCTAssertEqual(state.stageTitle, "Preparing your scan")
        XCTAssertEqual(state.scanned, 0)
    }

    @MainActor
    func test_failedScan_mapsToNeedsAttention() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(status: .failed, errors: ["Gmail needs reconnection."])
        )

        XCTAssertEqual(state.dashboardState, .needsAttention)
        XCTAssertEqual(state.headline, "An inbox needs attention")
    }

    @MainActor
    func test_activeProviderMonitoring_isPresentedAsAutomaticInboxMonitoring() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(status: .completed, monitoringHealth: "active")
        )

        XCTAssertEqual(state.monitoringState, .active)
        XCTAssertEqual(state.headline, "Monitoring new email")
        XCTAssertTrue(state.progressText.contains("checked automatically"))
    }

    @MainActor
    func test_reconnectRequiredMonitoring_needsAttention() {
        let state = EmailDiscoveryPresentationState(
            status: makeStatus(status: .completed, monitoringHealth: "reconnect_required")
        )

        XCTAssertEqual(state.monitoringState, .reconnectRequired)
        XCTAssertEqual(state.dashboardState, .needsAttention)
        XCTAssertEqual(state.headline, "An inbox needs attention")
    }

    @MainActor
    func test_candidateConfirmation_requiresPositiveAmountAndCurrency() {
        let candidate = makeCandidate()
        var edits = EmailCandidateEdits(candidate: candidate)
        edits.amount = nil
        edits.currency = "US"

        let issues = EmailDiscoveryPresentationState.confirmationIssues(for: candidate, edits: edits)

        XCTAssertTrue(issues.contains("Enter a positive amount."))
        XCTAssertTrue(issues.contains("Use a three-letter currency code."))
    }

    @MainActor
    func test_unmatchedCancellation_cannotBeConfirmed() {
        let candidate = makeCandidate(
            action: .review,
            eventType: "canceled",
            matchedSubscriptionID: nil
        )

        let issues = EmailDiscoveryPresentationState.confirmationIssues(
            for: candidate,
            edits: EmailCandidateEdits(candidate: candidate)
        )

        XCTAssertEqual(issues, ["This cancellation is not matched to a subscription."])
    }

    @MainActor
    func test_unusedServiceSuppression_isUnavailableForCancellation() {
        XCTAssertTrue(EmailDiscoveryPresentationState.canSuppress(makeCandidate()))
        XCTAssertFalse(
            EmailDiscoveryPresentationState.canSuppress(
                makeCandidate(action: .cancel, eventType: "canceled", matchedSubscriptionID: UUID())
            )
        )
    }

    @MainActor
    private func makeStatus(
        status: EmailScanAggregateStatus,
        stage: EmailScanStage = .idle,
        connectionCount: Int = 1,
        scanned: Int = 0,
        candidateMessages: Int = 0,
        pendingCount: Int = 0,
        errors: [String] = [],
        learningSummary: EmailScanLearningSummary? = nil,
        monitoringHealth: String? = nil
    ) -> EmailScanStatus {
        let connections = (0..<connectionCount).map { index in
            EmailConnectionSummary(
                id: UUID(),
                provider: index == 0 ? "google" : "microsoft",
                redactedEmail: "me••@example.com",
                lastScannedAt: nil,
                health: "connected",
                scanStatus: "idle",
                automaticMonitoringEnabled: true,
                monitoringHealth: monitoringHealth,
                monitoringFallbackActive: monitoringHealth == nil
            )
        }
        return EmailScanStatus(
            scanID: status == .idle ? nil : UUID(),
            status: status,
            stage: stage,
            connectionCount: connectionCount,
            scanned: scanned,
            candidateMessages: candidateMessages,
            detected: pendingCount,
            validationFailures: 0,
            pendingCount: pendingCount,
            candidates: [],
            suppressedMerchants: [],
            connections: connections,
            errors: errors,
            withheldAmbiguities: nil,
            learningSummary: learningSummary,
            runs: nil
        )
    }

    @MainActor
    private func makeCandidate(
        action: EmailCandidateAction = .add,
        eventType: String = "created",
        matchedSubscriptionID: UUID? = nil
    ) -> EmailSubscriptionCandidate {
        EmailSubscriptionCandidate(
            id: UUID(),
            matchedSubscriptionID: matchedSubscriptionID,
            suggestedAction: action,
            reviewStatus: .pending,
            merchantName: "Netflix",
            amount: 22.99,
            currency: "USD",
            billingCycle: .monthly,
            renewalDate: .now,
            category: .entertainment,
            eventType: eventType,
            confidence: 0.92,
            evidence: "A monthly subscription event was detected.",
            validationIssues: [],
            resolutionReason: nil,
            evidenceEvents: nil,
            createdAt: .now
        )
    }
}
