import Foundation

struct EmailDiscoveryPresentationState: Equatable {
    enum DashboardState: Equatable {
        case noInbox
        case scanning
        case reviewReady
        case upToDate
        case needsAttention
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
        if errorCount > 0 || status == .failed || status == .partial { return .needsAttention }
        if pendingCount > 0 { return .reviewReady }
        return .upToDate
    }

    var isMonitoringAutomatically: Bool {
        connections.contains { $0.automaticMonitoringEnabled == true }
    }

    var lastScannedAt: Date? {
        connections.compactMap(\.lastScannedAt).max()
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
        switch dashboardState {
        case .noInbox: "Connect an inbox"
        case .scanning: stageTitle
        case .reviewReady: "Changes are ready for review"
        case .upToDate: "No action needed"
        case .needsAttention: "An inbox needs attention"
        }
    }

    var progressText: String {
        switch dashboardState {
        case .noInbox:
            return "Read-only access. Disconnect it whenever you want."
        case .scanning:
            if scanned == 0 { return "Preparing \(connectionCount) connected inbox\(connectionCount == 1 ? "" : "es")." }
            return "\(scanned) messages checked · \(candidateMessages) likely billing emails"
        case .reviewReady:
            let noun = pendingCount == 1 ? "discovery" : "discoveries"
            return "\(pendingCount) \(noun) waiting for confirmation."
        case .needsAttention:
            return "Completed with \(errorCount) connection issue\(errorCount == 1 ? "" : "s")."
        case .upToDate:
            if nonActionableCount > 0 {
                return "We found billing history, but nothing safely needs your review."
            }
            return "Your inbox is connected and ready for the next scan."
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
