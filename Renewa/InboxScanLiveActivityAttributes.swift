import ActivityKit
import Foundation

nonisolated struct InboxScanLiveActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var stage: String
        var scanned: Int
        var connectionCount: Int
        var outcome: String?
        var discoveryCount: Int
        var route: String
        var batchID: String
    }

    var batchID: String
}

extension InboxScanLiveActivityAttributes.ContentState {
    init(status: EmailScanStatus) {
        stage = status.stage.rawValue
        scanned = status.scanned
        connectionCount = status.connectionCount
        outcome = status.status == .completed
            ? (status.pendingCount > 0 ? "review_ready" : "no_new_discoveries")
            : nil
        discoveryCount = status.pendingCount
        route = "inbox-intelligence"
        batchID = status.scanID?.uuidString ?? ""
    }
}
