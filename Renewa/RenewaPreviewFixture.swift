#if DEBUG
    import Foundation

    /// Sample data for SwiftUI previews and for simulator runs with no backend configured.
    /// Launch with `RENEWA_QA_FIXTURE=1` to boot straight into it.
    enum RenewaPreviewFixture {
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["RENEWA_QA_FIXTURE"] == "1"
        }

        /// `RENEWA_QA_FIXTURE_SIZE=single` reproduces the one-subscription screen the design is built around.
        static var isSingleSubscription: Bool {
            ProcessInfo.processInfo.environment["RENEWA_QA_FIXTURE_SIZE"] == "single"
        }

        static func apply(to store: AppStore) {
            store.profile = UserProfile(
                id: UUID(),
                displayName: "Meirzhan",
                defaultCurrency: "USD"
            )
            store.subscriptions = isSingleSubscription ? Array(subscriptions.prefix(1)) : subscriptions
            store.spendingSnapshots = snapshots
            store.insightReport = report
            store.hasLoadedSubscriptions = true
            store.hasLoadedInsightsData = true
            store.state = .ready
        }

        static func store() -> AppStore {
            let store = AppStore()
            apply(to: store)
            return store
        }

        static let subscriptions: [Subscription] = [
            subscription(
                name: "ChatGPT Plus",
                price: 20,
                cycle: .monthly,
                category: .work,
                daysAway: 4,
                tintHex: "43765C"
            ),
            subscription(
                name: "Netflix",
                price: 15.49,
                cycle: .monthly,
                category: .entertainment,
                daysAway: 12,
                tintHex: "A3663F"
            ),
            subscription(
                name: "iCloud+",
                price: 9.99,
                cycle: .monthly,
                category: .cloud,
                daysAway: 19,
                tintHex: "3F6B83"
            ),
            subscription(
                name: "Figma",
                price: 144,
                cycle: .yearly,
                category: .work,
                daysAway: 96,
                tintHex: "6F6858"
            ),
            subscription(
                name: "Headspace",
                price: 12.99,
                cycle: .monthly,
                category: .health,
                daysAway: 26,
                status: .canceled,
                tintHex: "C98D84"
            ),
        ]

        /// Six months of recorded history, ending on the month the app is being run in, so the
        /// Insights trend line and its category breakdown both have something to draw.
        private static var snapshots: [SpendingSnapshot] {
            let calendar = Calendar.current
            guard let thisMonth = calendar.dateInterval(of: .month, for: .now)?.start else {
                return []
            }

            let history: [[String: Decimal]] = [
                ["entertainment": 15.49, "work": 12, "cloud": 5.99],
                ["entertainment": 15.49, "work": 12, "cloud": 9.99],
                ["entertainment": 15.49, "work": 12, "cloud": 9.99, "learning": 5],
                ["entertainment": 15.49, "work": 24, "cloud": 9.99, "learning": 5],
                ["entertainment": 15.49, "work": 24, "cloud": 9.99, "learning": 5, "health": 12.99],
                ["entertainment": 15.49, "work": 32, "cloud": 9.99, "learning": 5, "health": 12.99],
            ]

            return history.enumerated().compactMap { index, categoryTotals in
                guard
                    let periodStart = calendar.date(
                        byAdding: .month,
                        value: index - (history.count - 1),
                        to: thisMonth
                    )
                else { return nil }

                return SpendingSnapshot(
                    id: UUID(),
                    periodStart: periodStart,
                    currency: "USD",
                    monthlyTotal: categoryTotals.values.reduce(0, +),
                    categoryTotals: categoryTotals
                )
            }
        }

        private static var report: InsightReport {
            InsightReport(
                summary: """
                    You will pay $73.47 across five renewals in the next 30 days. \
                    Monthly spend is up $39.99 since March, mostly from a second cloud plan in \
                    April and a doubled work tier in June. Headspace is canceled but still \
                    counted until its term ends.
                    """,
                cards: [
                    InsightCard(
                        title: "Work is now your largest category",
                        body: """
                            It has grown from $12.00 to $32.00 a month since March. \
                            Two plans renew within a week of each other.
                            """,
                        subscriptionIDs: subscriptions.filter { $0.category == .work }.map(\.id.uuidString),
                        eventIDs: []
                    ),
                    InsightCard(
                        title: "ChatGPT Plus renews first",
                        body: "It charges in four days, ahead of everything else you track.",
                        subscriptionIDs: subscriptions.prefix(1).map(\.id.uuidString),
                        eventIDs: []
                    ),
                ],
                generatedAt: Date().addingTimeInterval(-120),
                isAIGenerated: true,
                provenance: InsightProvenance(
                    source: .ai,
                    generatedAt: Date().addingTimeInterval(-120),
                    isCached: false,
                    evidence: InsightEvidenceSummary(
                        activeSubscriptionCount: 4,
                        billingEventCount: 22,
                        monthlySnapshotCount: 6
                    )
                )
            )
        }

        private static func subscription(
            name: String,
            price: Decimal,
            cycle: BillingCycle,
            category: SubscriptionCategory,
            daysAway: Int,
            status: SubscriptionStatus = .active,
            tintHex: String
        ) -> Subscription {
            Subscription(
                id: UUID(),
                userID: nil,
                name: name,
                price: price,
                currency: "USD",
                billingCycle: cycle,
                nextRenewalDate: Calendar.current.date(byAdding: .day, value: daysAway, to: .now) ?? .now,
                category: category,
                status: status,
                iconName: String(name.prefix(1)),
                brandID: nil,
                tintHex: tintHex,
                source: "manual",
                createdAt: nil,
                updatedAt: .now
            )
        }
    }
#endif
