import Foundation

struct EmailDiscoveryPresentationState: Equatable {
    let status: EmailScanAggregateStatus
    let stage: EmailScanStage
    let connectionCount: Int
    let scanned: Int
    let candidateMessages: Int
    let pendingCount: Int
    let errorCount: Int

    init(status: EmailScanStatus?) {
        self.status = status?.status ?? .idle
        stage = status?.stage ?? .idle
        connectionCount = status?.connections.count ?? 0
        scanned = status?.scanned ?? 0
        candidateMessages = status?.candidateMessages ?? 0
        pendingCount = status?.pendingCount ?? 0
        errorCount = status?.errors.count ?? 0
    }

    var isScanning: Bool {
        status == .queued || status == .running
    }

    var canStartScan: Bool {
        connectionCount > 0 && !isScanning
    }

    var headline: String {
        switch status {
        case .idle: connectionCount == 0 ? "Connect an inbox" : "Ready to discover"
        case .queued: "Scan queued"
        case .running:
            switch stage {
            case .fetching: "Checking new messages"
            case .filtering: "Finding billing signals"
            case .extracting: "Reading likely subscriptions"
            default: "Scanning inboxes"
            }
        case .completed: pendingCount > 0 ? "Ready for your review" : "You’re up to date"
        case .partial: "Some inboxes need attention"
        case .failed: "The scan couldn’t finish"
        }
    }

    var progressText: String {
        if isScanning {
            if scanned == 0 { return "Preparing \(connectionCount) connected inbox\(connectionCount == 1 ? "" : "es")." }
            return "\(scanned) messages checked · \(candidateMessages) billing candidates"
        }
        if pendingCount > 0 {
            let noun = pendingCount == 1 ? "discovery" : "discoveries"
            return "\(pendingCount) \(noun) waiting for confirmation."
        }
        if errorCount > 0 {
            return "Completed with \(errorCount) connection issue\(errorCount == 1 ? "" : "s")."
        }
        return connectionCount == 0
            ? "Mail access stays read-only and can be disconnected anytime."
            : "Only likely billing messages are sent for structured extraction."
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
