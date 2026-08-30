import Foundation

enum InboxScanPollingPolicy {
    static let fastPollCount = 60

    static func delayAfterSuccessfulPoll(_ pollCount: Int) -> Duration {
        .seconds(pollCount < fastPollCount ? 2 : 12)
    }

    static func retryDelay(for consecutiveFailures: Int) -> Duration {
        .seconds(min(30, max(3, 3 * max(1, consecutiveFailures))))
    }
}
