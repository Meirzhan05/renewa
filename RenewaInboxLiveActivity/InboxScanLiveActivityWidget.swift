import ActivityKit
import SwiftUI
import WidgetKit

struct InboxScanLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
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

struct InboxScanLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InboxScanLiveActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: icon(for: context.state))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.29, green: 0.56, blue: 0.46))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: context.state))
                        .font(.headline)
                    Text(detail(for: context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .activityBackgroundTint(Color(red: 0.96, green: 0.95, blue: 0.90))
            .activitySystemActionForegroundColor(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(for: context.state))
                        .foregroundStyle(Color(red: 0.29, green: 0.56, blue: 0.46))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.outcome == nil ? "Scanning" : "Complete")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: context.state))
                        Text(detail(for: context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: icon(for: context.state))
            } compactTrailing: {
                Text("\(context.state.scanned)")
                    .font(.caption2)
            } minimal: {
                Image(systemName: "envelope.badge")
            }
            .widgetURL(URL(string: "renewa://inbox-intelligence"))
            .keylineTint(Color(red: 0.29, green: 0.56, blue: 0.46))
        }
    }

    private func icon(for state: InboxScanLiveActivityAttributes.ContentState) -> String {
        if state.outcome == "review_ready" { return "checkmark.circle.fill" }
        if state.outcome == "no_new_discoveries" { return "tray.fill" }
        if state.outcome == "reconnect_required" { return "exclamationmark.triangle.fill" }
        return "envelope.badge"
    }

    private func title(for state: InboxScanLiveActivityAttributes.ContentState) -> String {
        switch state.outcome {
        case "review_ready":
            return state.discoveryCount == 1 ? "1 subscription ready to review" : "\(state.discoveryCount) subscriptions ready to review"
        case "no_new_discoveries":
            return "Inbox scan complete"
        case "reconnect_required":
            return "Reconnect an inbox to continue"
        default:
            return "Scanning your inbox"
        }
    }

    private func detail(for state: InboxScanLiveActivityAttributes.ContentState) -> String {
        switch state.outcome {
        case "review_ready":
            return "Open Renewa to decide what changes."
        case "no_new_discoveries":
            return "No new subscriptions were found."
        case "reconnect_required":
            return "Renewa needs access before it can finish."
        default:
            let inboxes = state.connectionCount == 1 ? "inbox" : "inboxes"
            return "Checked \(state.scanned) messages across \(state.connectionCount) \(inboxes)."
        }
    }
}

@main
struct InboxScanLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        InboxScanLiveActivityWidget()
    }
}
