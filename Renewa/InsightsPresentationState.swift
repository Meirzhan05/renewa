import Foundation

struct InsightsPresentationState: Equatable {
    enum Evidence: Equatable {
        case unresolved
        case activation
        case failure
        case dashboard
    }

    enum Commitment: Equatable {
        case noActiveSubscriptions
        case unavailable(excludedCount: Int)
        case partial(excludedCount: Int)
        case complete
    }

    enum Trend: Equatable {
        case building(periodCount: Int)
        case conversionUnavailable(periodCount: Int)
        case available
    }

    let evidence: Evidence
    let commitment: Commitment
    let trend: Trend

    init(
        hasLoadedInsightsData: Bool,
        isLoadingInsightReport: Bool,
        subscriptionCount: Int,
        snapshotPeriodCount: Int,
        hasInsightReport: Bool,
        hasInsightsError: Bool,
        activeSubscriptionCount: Int,
        unavailableConversionCount: Int,
        usableTrendPointCount: Int
    ) {
        let hasEvidence = subscriptionCount > 0 || snapshotPeriodCount > 0 || hasInsightReport

        if !hasLoadedInsightsData || (isLoadingInsightReport && !hasEvidence) {
            evidence = .unresolved
        } else if hasEvidence {
            evidence = .dashboard
        } else if hasInsightsError {
            evidence = .failure
        } else {
            evidence = .activation
        }

        if activeSubscriptionCount == 0 {
            commitment = .noActiveSubscriptions
        } else if unavailableConversionCount >= activeSubscriptionCount {
            commitment = .unavailable(excludedCount: activeSubscriptionCount)
        } else if unavailableConversionCount > 0 {
            commitment = .partial(excludedCount: unavailableConversionCount)
        } else {
            commitment = .complete
        }

        if usableTrendPointCount >= 2 {
            trend = .available
        } else if snapshotPeriodCount >= 2 {
            trend = .conversionUnavailable(periodCount: snapshotPeriodCount)
        } else {
            trend = .building(periodCount: snapshotPeriodCount)
        }
    }
}
