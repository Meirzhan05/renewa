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

        private static var snapshots: [SpendingSnapshot] {
            let calendar = Calendar.current
            guard let thisMonth = calendar.dateInterval(of: .month, for: .now)?.start,
                let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)
            else {
                return []
            }
            return [
                SpendingSnapshot(
                    id: UUID(),
                    periodStart: lastMonth,
                    currency: "USD",
                    monthlyTotal: 33.48,
                    categoryTotals: ["work": 12, "entertainment": 15.49, "cloud": 5.99]
                )
            ]
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
