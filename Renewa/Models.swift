import Foundation
import SwiftUI

enum BillingCycle: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case quarterly
    case yearly

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var monthlyFactor: Decimal {
        switch self {
        case .weekly: 4.345
        case .monthly: 1
        case .quarterly: 1 / 3
        case .yearly: 1 / 12
        }
    }
}

enum SubscriptionCategory: String, Codable, CaseIterable, Identifiable {
    case entertainment
    case work
    case cloud
    case health
    case learning
    case other

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .entertainment: RenewaTheme.sage
        case .work: RenewaTheme.sageLight
        case .cloud: RenewaTheme.sand
        case .health: .pink.opacity(0.7)
        case .learning: .blue.opacity(0.55)
        case .other: RenewaTheme.muted.opacity(0.5)
        }
    }
}

enum SubscriptionStatus: String, Codable {
    case active
    case canceled
    case paused

    var title: String { rawValue.capitalized }
}

enum ProfileAvatar: String, Codable, CaseIterable, Identifiable {
    case sage
    case sky
    case coral
    case plum
    case gold
    case graphite

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .sage: RenewaTheme.sage
        case .sky: Color(red: 0.34, green: 0.57, blue: 0.76)
        case .coral: RenewaTheme.coral
        case .plum: Color(red: 0.54, green: 0.42, blue: 0.65)
        case .gold: Color(red: 0.73, green: 0.58, blue: 0.24)
        case .graphite: Color(red: 0.28, green: 0.29, blue: 0.30)
        }
    }
}

struct Subscription: Identifiable, Codable, Hashable {
    var id: UUID
    var userID: UUID?
    var name: String
    var price: Decimal
    var currency: String
    var billingCycle: BillingCycle
    var nextRenewalDate: Date
    var category: SubscriptionCategory
    var status: SubscriptionStatus
    var iconName: String
    var brandID: String?
    var tintHex: String
    var source: String
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
        case price
        case currency
        case billingCycle = "billing_cycle"
        case nextRenewalDate = "next_renewal_date"
        case category
        case status
        case iconName = "icon_name"
        case brandID = "brand_id"
        case tintHex = "tint_hex"
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var monthlyCost: Decimal { price * billingCycle.monthlyFactor }
    var yearlyCost: Decimal { monthlyCost * 12 }

    var renewalDescription: String {
        let days = Calendar.current.dateComponents([.day], from: .now.startOfDay, to: nextRenewalDate.startOfDay).day ?? 0
        if days == 0 { return "Renews today" }
        if days == 1 { return "Renews tomorrow" }
        if days > 1 { return "Renews in \(days) days" }
        return "Renewal passed"
    }
}

struct Session: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval?
    let user: AuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case user
    }
}

struct AuthUser: Codable {
    let id: UUID
    let email: String?
}

struct UserProfile: Codable, Equatable {
    let id: UUID
    var displayName: String?
    var defaultCurrency: String
    var avatarKey: String
    var onboardingCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case defaultCurrency = "default_currency"
        case avatarKey = "avatar_key"
        case onboardingCompleted = "onboarding_completed"
    }

    init(
        id: UUID,
        displayName: String?,
        defaultCurrency: String,
        avatarKey: String = ProfileAvatar.sage.rawValue,
        onboardingCompleted: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultCurrency = defaultCurrency
        self.avatarKey = avatarKey
        self.onboardingCompleted = onboardingCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        defaultCurrency = try container.decodeIfPresent(String.self, forKey: .defaultCurrency) ?? "USD"
        avatarKey = try container.decodeIfPresent(String.self, forKey: .avatarKey) ?? ProfileAvatar.sage.rawValue
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
    }
}

enum EmailScanAggregateStatus: String, Codable {
    case idle
    case queued
    case running
    case completed
    case partial
    case failed
}

enum EmailScanStage: String, Codable {
    case idle
    case queued
    case fetching
    case filtering
    case extracting
    case reviewReady = "review_ready"
    case completed
    case failed
}

enum EmailCandidateAction: String, Codable {
    case add
    case update
    case cancel
    case review

    var title: String {
        switch self {
        case .add: "New subscription"
        case .update: "Subscription update"
        case .cancel: "Cancellation"
        case .review: "Needs a match"
        }
    }
}

enum EmailCandidateReviewStatus: String, Codable {
    case pending
    case confirmed
    case ignored
}

struct EmailConnectionSummary: Identifiable, Codable, Hashable {
    let id: UUID
    let provider: String
    let redactedEmail: String?
    let lastScannedAt: Date?
    let health: String
    let scanStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case redactedEmail = "redacted_email"
        case lastScannedAt = "last_scanned_at"
        case health
        case scanStatus = "scan_status"
    }

    var providerTitle: String { provider.capitalized }
}

struct EmailSubscriptionCandidate: Identifiable, Codable, Hashable {
    let id: UUID
    let matchedSubscriptionID: UUID?
    let suggestedAction: EmailCandidateAction
    let reviewStatus: EmailCandidateReviewStatus
    let merchantName: String
    let amount: Decimal?
    let currency: String?
    let billingCycle: BillingCycle?
    let renewalDate: Date?
    let category: SubscriptionCategory
    let eventType: String
    let confidence: Double
    let evidence: String
    let validationIssues: [String]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case matchedSubscriptionID = "matched_subscription_id"
        case suggestedAction = "suggested_action"
        case reviewStatus = "review_status"
        case merchantName = "merchant_name"
        case amount
        case currency
        case billingCycle = "billing_cycle"
        case renewalDate = "renewal_date"
        case category
        case eventType = "event_type"
        case confidence
        case evidence
        case validationIssues = "validation_issues"
        case createdAt = "created_at"
    }

    var displayAmount: String {
        guard let amount, let currency else { return "Amount needs review" }
        return amount.currencyText(code: currency)
    }
}

struct EmailMerchantSuppression: Identifiable, Codable, Hashable {
    let canonicalMerchantKey: String
    let createdAt: Date

    var id: String { canonicalMerchantKey }

    var merchantTitle: String {
        canonicalMerchantKey
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case canonicalMerchantKey = "canonical_merchant_key"
        case createdAt = "created_at"
    }
}

struct EmailScanStatus: Codable, Equatable {
    let scanID: UUID?
    let status: EmailScanAggregateStatus
    let stage: EmailScanStage
    let connectionCount: Int
    let scanned: Int
    let candidateMessages: Int
    let detected: Int
    let validationFailures: Int?
    let pendingCount: Int
    let candidates: [EmailSubscriptionCandidate]
    let suppressedMerchants: [EmailMerchantSuppression]
    let connections: [EmailConnectionSummary]
    let errors: [String]

    enum CodingKeys: String, CodingKey {
        case scanID = "scan_id"
        case status
        case stage
        case connectionCount = "connection_count"
        case scanned
        case candidateMessages = "candidate_messages"
        case detected
        case validationFailures = "validation_failures"
        case pendingCount = "pending_count"
        case candidates
        case suppressedMerchants = "suppressed_merchants"
        case connections
        case errors
    }

    var isActive: Bool {
        status == .queued || status == .running
    }
}

struct EmailCandidateEdits: Equatable {
    var merchantName: String
    var amount: Decimal?
    var currency: String
    var billingCycle: BillingCycle
    var renewalDate: Date
    var category: SubscriptionCategory

    init(candidate: EmailSubscriptionCandidate) {
        merchantName = candidate.merchantName
        amount = candidate.amount
        currency = candidate.currency ?? "USD"
        billingCycle = candidate.billingCycle ?? .monthly
        renewalDate = candidate.renewalDate ?? Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
        category = candidate.category
    }
}

struct EmailCandidateDecisionResponse: Codable {
    let candidateID: UUID
    let reviewStatus: EmailCandidateReviewStatus
    let appliedSubscriptionID: UUID?
    let idempotent: Bool?

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case reviewStatus = "review_status"
        case appliedSubscriptionID = "applied_subscription_id"
        case idempotent
    }
}

struct EmailDisconnectResponse: Codable {
    let disconnected: Bool
    let remoteRevoked: Bool

    enum CodingKeys: String, CodingKey {
        case disconnected
        case remoteRevoked = "remote_revoked"
    }
}

struct SpendingSnapshot: Identifiable, Codable, Hashable {
    let id: UUID
    let periodStart: Date
    let currency: String
    let monthlyTotal: Decimal
    let categoryTotals: [String: Decimal]

    enum CodingKeys: String, CodingKey {
        case id
        case periodStart = "period_start"
        case currency
        case monthlyTotal = "monthly_total"
        case categoryTotals = "category_totals"
    }
}

struct InsightCard: Codable, Hashable, Identifiable {
    let title: String
    let body: String
    let subscriptionIDs: [String]
    let eventIDs: [String]

    var id: String { "\(title)|\(body)" }

    enum CodingKeys: String, CodingKey {
        case title
        case body
        case subscriptionIDs = "subscription_ids"
        case eventIDs = "event_ids"
    }
}

struct InsightReport: Codable, Hashable {
    let summary: String
    let cards: [InsightCard]
    let generatedAt: Date
    let isAIGenerated: Bool

    enum CodingKeys: String, CodingKey {
        case summary
        case cards
        case generatedAt = "generated_at"
        case isAIGenerated = "is_ai_generated"
    }
}

struct InsightRefreshResponse: Codable {
    let report: InsightReport?
    let cached: Bool
    let fallback: Bool
}

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }
}

extension Decimal {
    var currencyText: String {
        currencyText(code: "USD")
    }

    func currencyText(code: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = code
        formatter.currencySymbol =
            [
                "USD": "$",
                "EUR": "€",
                "GBP": "£",
                "KZT": "₸",
                "CAD": "CA$",
                "AUD": "A$",
                "JPY": "¥",
            ][code] ?? code
        formatter.maximumFractionDigits = 2
        return formatter.string(from: self as NSDecimalNumber) ?? "$0"
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
