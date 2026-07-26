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
        case onboarding
        case ready
    }

    private let client = SupabaseClient()
    private let keychain = KeychainStore()
    private let currencyRateClient = CurrencyRateClient()

    var state: LaunchState = .loading
    var session: Session?
    var profile: UserProfile?
    var subscriptions: [Subscription] = []
    var errorMessage: String?
    var isBusy = false
    var isRefreshingExchangeRates = false
    var exchangeRateErrorMessage: String?
    private var exchangeRateBaseCurrency: String?
    private var exchangeRates: [String: Decimal] = [:]

    var activeSubscriptions: [Subscription] {
        subscriptions.filter { $0.status == .active }
    }

    var inactiveSubscriptions: [Subscription] {
        subscriptions.filter { $0.status != .active }
    }

    var monthlySpend: Decimal {
        activeSubscriptions
            .compactMap(convertedMonthlyCost(for:))
            .reduce(0, +)
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

    var profileAvatar: ProfileAvatar {
        ProfileAvatar(rawValue: profile?.avatarKey ?? "") ?? .sage
    }

    var foreignCurrencySubscriptionCount: Int {
        activeSubscriptions.count(where: { $0.currency != defaultCurrency })
    }

    var unavailableConversionCount: Int {
        activeSubscriptions.count { subscription in
            subscription.currency != defaultCurrency && convertedAmount(subscription.price, from: subscription.currency) == nil
        }
    }

    var exchangeRateStatus: String {
        if isRefreshingExchangeRates {
            return "Updating rates"
        }
        if unavailableConversionCount > 0 {
            return "Rates unavailable"
        }
        return foreignCurrencySubscriptionCount > 0 ? "Exchange rates" : "Your currency"
    }

    func bootstrap() async {
        guard AppConfiguration.current.isConfigured else {
            state = .configurationRequired
            return
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] == "registration" {
            keychain.clear()
            session = nil
            state = .signedOut
            return
        }
#endif
        do {
            guard let data = try keychain.load() else {
                if let credentials = AppConfiguration.current.localDebugCredentials {
                    _ = await authenticate(
                        email: credentials.email,
                        password: credentials.password,
                        displayName: nil,
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
            state = authenticatedDestination
        } catch {
            keychain.clear()
            session = nil
            state = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func authenticate(
        email: String,
        password: String,
        displayName: String?,
        createAccount: Bool
    ) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            if createAccount {
                let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmedName.isEmpty else {
                    errorMessage = "Enter your name to create an account."
                    return false
                }
                guard let created = try await client.signUp(
                    email: email,
                    password: password,
                    displayName: trimmedName
                ) else {
                    errorMessage = "Check your inbox to confirm your email, then sign in."
                    return false
                }
                session = created
            } else {
                session = try await client.signIn(email: email, password: password)
            }
            try persistSession()
            try await refreshData()
            state = authenticatedDestination
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func googleAuthorization() throws -> OAuthAuthorization {
        try client.googleAuthorization()
    }

    func completeGoogleSignIn(callbackURL: URL, codeVerifier: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            errorMessage = "Google sign-in returned an invalid callback."
            return false
        }
        if let message = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            ?? components.queryItems?.first(where: { $0.name == "error" })?.value {
            errorMessage = message
            return false
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            errorMessage = "Google sign-in did not return an authorization code."
            return false
        }
        do {
            session = try await client.exchangeGoogleAuthorizationCode(code, verifier: codeVerifier)
            try persistSession()
            try await refreshData()
            state = authenticatedDestination
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
        exchangeRates = [:]
        exchangeRateBaseCurrency = nil
        exchangeRateErrorMessage = nil
        state = .signedOut
    }

    func refreshData() async throws {
        guard let accessToken = session?.accessToken else { return }
        async let subscriptionsRequest = client.fetchSubscriptions(accessToken: accessToken)
        async let profileRequest = client.fetchProfile(accessToken: accessToken)
        subscriptions = try await subscriptionsRequest
        profile = try await profileRequest
        await refreshExchangeRates()
    }

    func refreshSubscriptions() async throws {
        guard let accessToken = session?.accessToken else { return }
        subscriptions = try await client.fetchSubscriptions(accessToken: accessToken)
        await refreshExchangeRates()
    }

    func completeOnboarding(displayName: String, currency: String, avatar: ProfileAvatar) async -> Bool {
        await saveProfile(
            displayName: displayName,
            currency: currency,
            avatar: avatar,
            onboardingCompleted: true
        )
    }

    func updateProfile(displayName: String, currency: String, avatar: ProfileAvatar) async -> Bool {
        await saveProfile(
            displayName: displayName,
            currency: currency,
            avatar: avatar,
            onboardingCompleted: profile?.onboardingCompleted ?? true
        )
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
            await refreshExchangeRates()
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

    func convertedAmount(_ amount: Decimal, from sourceCurrency: String) -> Decimal? {
        let source = sourceCurrency.uppercased()
        let target = defaultCurrency.uppercased()
        if source == target {
            return amount
        }
        guard exchangeRateBaseCurrency == target,
              let rate = exchangeRates[source] else {
            return nil
        }
        return amount * rate
    }

    func convertedMonthlyCost(for subscription: Subscription) -> Decimal? {
        convertedAmount(subscription.monthlyCost, from: subscription.currency)
    }

    private func refreshExchangeRates() async {
        let target = defaultCurrency.uppercased()
        let sourceCurrencies = Set(activeSubscriptions.map { $0.currency.uppercased() })
        exchangeRateBaseCurrency = nil
        exchangeRates = [:]
        exchangeRateErrorMessage = nil
        isRefreshingExchangeRates = true
        defer { isRefreshingExchangeRates = false }

        do {
            let snapshot = try await currencyRateClient.latestRates(
                from: sourceCurrencies,
                to: target
            )
            exchangeRateBaseCurrency = snapshot.baseCurrency
            exchangeRates = snapshot.rates
        } catch {
            exchangeRateErrorMessage = error.localizedDescription
        }
    }

    private func persistSession() throws {
        guard let session else { return }
        try keychain.save(JSONEncoder().encode(session))
    }

    private var authenticatedDestination: LaunchState {
        profile?.onboardingCompleted == false ? .onboarding : .ready
    }

    private func saveProfile(
        displayName: String,
        currency: String,
        avatar: ProfileAvatar,
        onboardingCompleted: Bool
    ) async -> Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let session else {
            errorMessage = "Enter a display name before saving."
            return false
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            profile = try await client.updateProfile(
                id: session.user.id,
                displayName: trimmedName,
                defaultCurrency: currency,
                avatarKey: avatar.rawValue,
                onboardingCompleted: onboardingCompleted,
                accessToken: session.accessToken
            )
            await refreshExchangeRates()
            if onboardingCompleted {
                state = .ready
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
