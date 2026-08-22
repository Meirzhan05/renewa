import Foundation

struct InsightsSummaryPresentationState: Equatable {
    enum Source: Equatable {
        case ai(isCached: Bool)
        case deterministic
    }

    let source: Source
    let generatedAt: Date
    let evidence: InsightEvidenceSummary?

    init(report: InsightReport) {
        generatedAt = report.provenance?.generatedAt ?? report.generatedAt
        evidence = report.provenance?.evidence

        switch report.provenance?.source {
        case .ai:
            source = .ai(isCached: report.provenance?.isCached ?? false)
        case .deterministic:
            source = .deterministic
        case nil:
            source = report.isAIGenerated ? .ai(isCached: false) : .deterministic
        }
    }

    var title: String {
        switch source {
        case .ai:
            "Renewa’s read"
        case .deterministic:
            "Basic subscription summary"
        }
    }

    var sourceLabel: String {
        switch source {
        case .ai(isCached: true):
            "AI-generated · Cached"
        case .ai(isCached: false):
            "AI-generated"
        case .deterministic:
            "Basic subscription summary"
        }
    }

    var isAIDegraded: Bool {
        if case .deterministic = source { return true }
        return false
    }

    var evidenceLabel: String? {
        guard let evidence else { return nil }
        var parts: [String] = []
        if evidence.activeSubscriptionCount > 0 {
            parts.append("\(evidence.activeSubscriptionCount) active \(noun(evidence.activeSubscriptionCount, singular: "subscription"))")
        }
        if evidence.billingEventCount > 0 {
            parts.append("\(evidence.billingEventCount) billing \(noun(evidence.billingEventCount, singular: "event"))")
        }
        if evidence.monthlySnapshotCount > 0 {
            parts.append("\(evidence.monthlySnapshotCount) monthly \(noun(evidence.monthlySnapshotCount, singular: "snapshot"))")
        }
        guard !parts.isEmpty else { return nil }
        return "Based on " + naturalLanguageList(parts)
    }

    private func noun(_ count: Int, singular: String) -> String {
        count == 1 ? singular : "\(singular)s"
    }

    private func naturalLanguageList(_ values: [String]) -> String {
        switch values.count {
        case 0:
            ""
        case 1:
            values[0]
        case 2:
            values.joined(separator: " and ")
        default:
            "\(values.dropLast().joined(separator: ", ")), and \(values.last ?? "")"
        }
    }
}
