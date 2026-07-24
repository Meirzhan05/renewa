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

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case defaultCurrency = "default_currency"
    }
}

struct EmailScanResult: Codable {
    let scanned: Int
    let detected: Int
    let added: Int
    let canceled: Int
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
        formatter.currencyCode = code
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
