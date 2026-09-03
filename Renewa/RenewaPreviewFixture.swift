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

            if let scenario = InboxScenario.current {
                store.emailScanStatus = emailScanStatus(scenario)
                store.isLoadingEmailDiscovery = scenario == .loading
            }
        }

        /// The Inbox screen's states, addressable from `RENEWA_QA_SCREEN` so each one can be
        /// booted in the simulator as well as opened in a preview.
        enum InboxScenario: String, CaseIterable {
            case reviewReady = "inbox"
            case empty = "inbox-empty"
            case scanning = "inbox-scanning"
            case clear = "inbox-clear"
            case failed = "inbox-failed"
            case reconnect = "inbox-reconnect"
            case loading = "inbox-loading"
            /// Empty inbox with the connect sheet already open.
            case connect = "inbox-connect"
            /// Review queue with the "add it anyway?" warning already raised on the first card, so
            /// the advisory path is inspectable without a merchant that has a real cancellation.
            case warned = "inbox-warned"

            static var current: InboxScenario? {
                ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"]
                    .flatMap(InboxScenario.init(rawValue:))
            }
        }

        static func emailScanStatus(_ scenario: InboxScenario) -> EmailScanStatus? {
            switch scenario {
            case .loading:
                return nil
            case .empty, .connect:
                return inboxStatus(status: .idle, stage: .idle, scanned: 0, connections: [])
            case .scanning:
                return inboxStatus(
                    status: .running,
                    stage: .fetching,
                    scanned: 1146,
                    connections: [inboxConnection()]
                )
            case .reviewReady, .warned:
                return inboxStatus(
                    status: .completed,
                    stage: .reviewReady,
                    scanned: 3204,
                    candidates: [
                        inboxCandidate(
                            "Figma Professional",
                            amount: 15,
                            evidence: "Receipt from figma.com · 4 minutes ago"
                        ),
                        inboxCandidate(
                            "Duolingo Super",
                            amount: 12.99,
                            evidence: "Free trial, first charge Sep 2 · Aug 19"
                        ),
                        inboxCandidate(
                            "Adobe Creative Cloud",
                            amount: nil,
                            evidence: "Order confirmation, no renewal date named · Aug 20",
                            action: .review,
                            validationIssues: ["missing_amount"]
                        ),
                    ],
                    connections: [
                        inboxConnection(),
                        inboxConnection(provider: "microsoft", email: "alex•••@contoso.com"),
                    ]
                )
            case .clear:
                return inboxStatus(
                    status: .completed,
                    stage: .completed,
                    scanned: 3204,
                    connections: [inboxConnection()],
                    learning: [
                        EmailScanLearningItem(
                            merchantName: "Headspace",
                            outcome: .ended,
                            eventType: "cancellation",
                            receivedAt: Date().addingTimeInterval(-60 * 60 * 30),
                            explanation: "The cancellation email matched a subscription you had already ended."
                        ),
                        EmailScanLearningItem(
                            merchantName: "Notion",
                            outcome: .uncertain,
                            eventType: "receipt",
                            receivedAt: Date().addingTimeInterval(-60 * 60 * 52),
                            explanation: "The receipt did not name a billing period, so nothing was added."
                        ),
                    ]
                )
            case .failed:
                return inboxStatus(
                    status: .failed,
                    stage: .failed,
                    scanned: 412,
                    connections: [inboxConnection()],
                    errors: ["The analysis service was unavailable partway through this scan."]
                )
            case .reconnect:
                return inboxStatus(
                    status: .partial,
                    stage: .failed,
                    scanned: 118,
                    connections: [
                        inboxConnection(
                            health: "attention",
                            monitoringHealth: "reconnect_required",
                            monitoringError: "Google sign-in expired. Reconnect to keep reading new mail."
                        )
                    ],
                    errors: ["Google sign-in expired."]
                )
            }
        }

        static func inboxConnection(
            provider: String = "google",
            email: String = "alex.k•••@gmail.com",
            health: String = "healthy",
            monitoringHealth: String = "active",
            monitoringError: String? = nil
        ) -> EmailConnectionSummary {
            let lastScannedAt = Date().addingTimeInterval(-780)
            return EmailConnectionSummary(
                id: UUID(),
                provider: provider,
                redactedEmail: email,
                lastScannedAt: lastScannedAt,
                health: health,
                scanStatus: "completed",
                automaticMonitoringEnabled: true,
                monitoringHealth: monitoringHealth,
                monitoringError: monitoringError,
                monitoringExpiresAt: nil,
                lastAutomaticScanAt: lastScannedAt,
                monitoringFallbackActive: false
            )
        }

        static func inboxCandidate(
            _ name: String,
            amount: Decimal?,
            evidence: String,
            action: EmailCandidateAction = .add,
            validationIssues: [String] = []
        ) -> EmailSubscriptionCandidate {
            EmailSubscriptionCandidate(
                id: UUID(),
                matchedSubscriptionID: nil,
                suggestedAction: action,
                reviewStatus: .pending,
                merchantName: name,
                amount: amount,
                currency: amount == nil ? nil : "USD",
                billingCycle: .monthly,
                renewalDate: Date().addingTimeInterval(60 * 60 * 24 * 21),
                category: .entertainment,
                eventType: "renewal",
                confidence: 0.82,
                evidence: evidence,
                validationIssues: validationIssues,
                resolutionReason: nil,
                evidenceEvents: nil,
                createdAt: Date().addingTimeInterval(-240)
            )
        }

        static func inboxStatus(
            status: EmailScanAggregateStatus,
            stage: EmailScanStage,
            scanned: Int,
            candidates: [EmailSubscriptionCandidate] = [],
            connections: [EmailConnectionSummary],
            errors: [String] = [],
            learning: [EmailScanLearningItem] = []
        ) -> EmailScanStatus {
            EmailScanStatus(
                scanID: UUID(),
                status: status,
                stage: stage,
                connectionCount: connections.count,
                scanned: scanned,
                candidateMessages: scanned / 24,
                detected: candidates.count,
                validationFailures: 0,
                pendingCount: candidates.count,
                candidates: candidates,
                suppressedMerchants: [],
                connections: connections,
                errors: errors,
                withheldAmbiguities: 0,
                learningSummary: learning.isEmpty
                    ? nil
                    : EmailScanLearningSummary(
                        endedCount: learning.filter { $0.outcome == .ended }.count,
                        uncertainCount: learning.filter { $0.outcome == .uncertain }.count,
                        items: learning
                    ),
                runs: nil,
                executionCounts: nil
            )
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
