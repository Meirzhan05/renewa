import Foundation

struct EmailLatestCheckSummary: Equatable {
    let inboxLabel: String
    let completedAt: Date
    let outcome: String
    let checkedMessageCount: Int?
    let likelyBillingMessageCount: Int?
}

struct EmailDiscoveryPresentationState: Equatable {
    enum DashboardState: Equatable {
        case noInbox
        case scanning
        case reviewReady
        case upToDate
        case needsAttention
    }

    enum MonitoringState: Equatable {
        case notConfigured
        case active
        case checking
        case fallback
        case reconnectRequired
    }

    let status: EmailScanAggregateStatus
    let stage: EmailScanStage
    let connectionCount: Int
    let scanned: Int
    let candidateMessages: Int
    let pendingCount: Int
    let errorCount: Int
    let withheldAmbiguities: Int
    let validationFailures: Int
    let learningSummary: EmailScanLearningSummary?
    let connections: [EmailConnectionSummary]
    let executionCounts: EmailScanExecutionCounts?

    init(status: EmailScanStatus?) {
        self.status = status?.status ?? .idle
        stage = status?.stage ?? .idle
        connectionCount = status?.connections.count ?? 0
        scanned = status?.scanned ?? 0
        candidateMessages = status?.candidateMessages ?? 0
        pendingCount = status?.pendingCount ?? 0
        errorCount = status?.errors.count ?? 0
        withheldAmbiguities = status?.withheldAmbiguities ?? 0
        validationFailures = status?.validationFailures ?? 0
        learningSummary = status?.learningSummary
        connections = status?.connections ?? []
        executionCounts = status?.executionCounts
    }

    var isScanning: Bool {
        status == .queued || status == .running
    }

    var canStartScan: Bool {
        connectionCount > 0 && !isScanning
    }

    var dashboardState: DashboardState {
        if connectionCount == 0 { return .noInbox }
        if isScanning { return .scanning }
        if monitoringState == .reconnectRequired { return .needsAttention }
        if errorCount > 0 || status == .failed || status == .partial { return .needsAttention }
        if pendingCount > 0 { return .reviewReady }
        return .upToDate
    }

    var isMonitoringAutomatically: Bool {
        monitoringState == .active || monitoringState == .checking
    }

    var monitoringState: MonitoringState {
        guard !connections.isEmpty else { return .notConfigured }
        if connections.contains(where: { $0.monitoringHealth == "reconnect_required" || $0.health == "attention" }) {
            return .reconnectRequired
        }
        if connections.contains(where: { $0.monitoringHealth == "checking" }) { return .checking }
        if connections.allSatisfy({ $0.monitoringHealth == "active" }) { return .active }
        if connections.contains(where: { $0.monitoringFallbackActive == true || $0.automaticMonitoringEnabled == true }) {
            return .fallback
        }
        return .notConfigured
    }

    var lastScannedAt: Date? {
        connections.compactMap(\.lastScannedAt).max()
    }

    var latestCheck: EmailLatestCheckSummary? {
        guard !isScanning,
            dashboardState == .upToDate || dashboardState == .reviewReady,
            let completedAt = lastScannedAt
        else {
            return nil
        }

        let inboxLabel: String
        if connections.count == 1, let connection = connections.first {
            inboxLabel = "\(connection.providerTitle) inbox"
        } else {
            inboxLabel = "\(connections.count) connected inboxes"
        }

        let checkedMessageCount = scanned > 0 ? scanned : nil
        let likelyBillingMessageCount = candidateMessages > 0 ? candidateMessages : nil
        let outcome =
            pendingCount > 0
            ? "New subscription changes are ready to review."
            : "No new subscription changes need review."

        return EmailLatestCheckSummary(
            inboxLabel: inboxLabel,
            completedAt: completedAt,
            outcome: outcome,
            checkedMessageCount: checkedMessageCount,
            likelyBillingMessageCount: likelyBillingMessageCount
        )
    }

    var endedCount: Int { learningSummary?.endedCount ?? 0 }
    var uncertainCount: Int { learningSummary?.uncertainCount ?? 0 }

    var nonActionableCount: Int {
        endedCount + uncertainCount + withheldAmbiguities + validationFailures
    }

    var stageTitle: String {
        switch stage {
        case .fetching: "Checking messages"
        case .filtering: "Finding billing signals"
        case .extracting: "Checking subscription evidence"
        case .queued: "Preparing your scan"
        default: "Scanning connected inboxes"
        }
    }

    var headline: String {
        if status == .cancelled { return "Inbox scan stopped" }
        return switch dashboardState {
        case .noInbox: "Connect an inbox"
        case .scanning: stageTitle
        case .reviewReady: "Changes are ready for review"
        case .upToDate:
            switch monitoringState {
            case .active: "Monitoring new email"
            case .checking: "Checking new email"
            case .fallback: "Daily checks are active"
            case .reconnectRequired: "An inbox needs attention"
            case .notConfigured: "No action needed"
            }
        case .needsAttention: "An inbox needs attention"
        }
    }

    var progressText: String {
        if status == .cancelled {
            return pendingCount > 0
                ? "Anything already found is still ready for your review."
                : "You can start another scan whenever you’re ready."
        }
        switch dashboardState {
        case .noInbox:
            return "Read-only access. Disconnect it whenever you want."
        case .scanning:
            if let executionCounts, executionCounts.retrying > 0 {
                return "Retrying \(executionCounts.retrying) page\(executionCounts.retrying == 1 ? "" : "s") safely."
            }
            if let executionCounts, executionCounts.queued > 0 || executionCounts.analyzing > 0 {
                let parts = [
                    executionCounts.analyzing > 0 ? "\(executionCounts.analyzing) analyzing" : nil,
                    executionCounts.queued > 0 ? "\(executionCounts.queued) waiting" : nil,
                ].compactMap { $0 }.joined(separator: " · ")
                return "\(scanned) messages fetched · \(parts)"
            }
            if scanned == 0 { return "Preparing \(connectionCount) connected inbox\(connectionCount == 1 ? "" : "es")." }
            return "\(scanned) messages checked · \(candidateMessages) likely billing emails"
        case .reviewReady:
            let noun = pendingCount == 1 ? "discovery" : "discoveries"
            return "\(pendingCount) \(noun) waiting for confirmation."
        case .needsAttention:
            return "Completed with \(errorCount) connection issue\(errorCount == 1 ? "" : "s")."
        case .upToDate:
            switch monitoringState {
            case .active:
                return "New inbox activity is checked automatically. You only need to review meaningful changes."
            case .checking:
                return "A server-side check is in progress. You can leave Renewa while it finishes."
            case .fallback:
                return "Daily reconciliation is active while live inbox monitoring needs attention."
            case .reconnectRequired:
                return "Reconnect this inbox to resume automatic monitoring."
            case .notConfigured:
                break
            }
            if nonActionableCount > 0 {
                return "We found billing history, but nothing safely needs your review."
            }
            return "Your inbox is connected. Check now whenever you want an immediate update."
        }
    }

    static func canSuppress(_ candidate: EmailSubscriptionCandidate) -> Bool {
        candidate.eventType != "canceled" && candidate.suggestedAction != .cancel
    }

    static func confirmationIssues(
        for candidate: EmailSubscriptionCandidate,
        edits: EmailCandidateEdits
    ) -> [String] {
        var issues: [String] = []
        if edits.merchantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Enter a subscription name.")
        }
        if candidate.eventType == "canceled" {
            if candidate.matchedSubscriptionID == nil {
                issues.append("This cancellation is not matched to a subscription.")
            }
            return issues
        }
        if (edits.amount ?? 0) <= 0 {
            issues.append("Enter a positive amount.")
        }
        if edits.currency.count != 3 {
            issues.append("Use a three-letter currency code.")
        }
        return issues
    }
}
