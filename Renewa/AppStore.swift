import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppStore {
    enum LaunchState: Equatable {
        case loading
        case configurationRequired
        case signedOut
        case ready
    }

    private let client = SupabaseClient()
    private let keychain = KeychainStore()

    var state: LaunchState = .loading
    var session: Session?
    var profile: UserProfile?
    var subscriptions: [Subscription] = []
    var errorMessage: String?
    var isBusy = false

    var activeSubscriptions: [Subscription] {
        subscriptions.filter { $0.status == .active }
    }

    var inactiveSubscriptions: [Subscription] {
        subscriptions.filter { $0.status != .active }
    }

    var monthlySpend: Decimal {
        activeSubscriptions
            .filter { $0.currency == defaultCurrency }
            .reduce(0) { $0 + $1.monthlyCost }
    }

    var yearlySpend: Decimal { monthlySpend * 12 }

    var displayName: String {
        if let displayName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if let localPart = session?.user.email?.split(separator: "@").first {
            return String(localPart).capitalized
        }
        return "there"
    }

    var defaultCurrency: String {
        profile?.defaultCurrency ?? "USD"
    }

    var foreignCurrencySubscriptionCount: Int {
        activeSubscriptions.count(where: { $0.currency != defaultCurrency })
    }

    func bootstrap() async {
        guard AppConfiguration.current.isConfigured else {
            state = .configurationRequired
            return
        }
        do {
            guard let data = try keychain.load() else {
                if let credentials = AppConfiguration.current.localDebugCredentials {
                    _ = await authenticate(
                        email: credentials.email,
                        password: credentials.password,
                        createAccount: false
                    )
                    return
                }
                state = .signedOut
                return
            }
            let cached = try JSONDecoder().decode(Session.self, from: data)
            if let expiresAt = cached.expiresAt, expiresAt < Date().timeIntervalSince1970 + 60 {
                session = try await client.refresh(using: cached.refreshToken)
                try persistSession()
            } else {
                session = cached
            }
            try await refreshData()
            state = .ready
        } catch {
            keychain.clear()
            session = nil
            state = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func authenticate(email: String, password: String, createAccount: Bool) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            if createAccount {
                guard let created = try await client.signUp(email: email, password: password) else {
                    errorMessage = "Check your inbox to confirm your email, then sign in."
                    return false
                }
                session = created
            } else {
                session = try await client.signIn(email: email, password: password)
            }
            try persistSession()
            try await refreshData()
            state = .ready
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        if let accessToken = session?.accessToken {
            try? await client.signOut(accessToken: accessToken)
        }
        keychain.clear()
        session = nil
        profile = nil
        subscriptions = []
        state = .signedOut
    }

    func refreshData() async throws {
        guard let accessToken = session?.accessToken else { return }
        async let subscriptionsRequest = client.fetchSubscriptions(accessToken: accessToken)
        async let profileRequest = client.fetchProfile(accessToken: accessToken)
        subscriptions = try await subscriptionsRequest
        profile = try await profileRequest
    }

    func refreshSubscriptions() async throws {
        guard let accessToken = session?.accessToken else { return }
        subscriptions = try await client.fetchSubscriptions(accessToken: accessToken)
    }

    func add(_ subscription: Subscription) async -> Bool {
        errorMessage = nil
        guard let accessToken = session?.accessToken else { return false }
        do {
            let created = try await client.createSubscription(subscription, accessToken: accessToken)
            withAnimation(RenewaMotion.standard) {
                subscriptions.append(created)
                subscriptions.sort { $0.nextRenewalDate < $1.nextRenewalDate }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ subscription: Subscription) async {
        guard let accessToken = session?.accessToken else { return }
        do {
            try await client.deleteSubscription(id: subscription.id, accessToken: accessToken)
            withAnimation(RenewaMotion.standard) {
                subscriptions.removeAll { $0.id == subscription.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func emailAuthorizationURL(provider: String) async throws -> URL {
        guard let accessToken = session?.accessToken else { throw APIError.notConfigured }
        return try await client.mailAuthorizationURL(provider: provider, accessToken: accessToken)
    }

    func scanEmail() async throws -> EmailScanResult {
        guard let accessToken = session?.accessToken else { throw APIError.notConfigured }
        let result = try await client.scanEmail(accessToken: accessToken)
        try await refreshSubscriptions()
        return result
    }

    private func persistSession() throws {
        guard let session else { return }
        try keychain.save(JSONEncoder().encode(session))
    }
}
