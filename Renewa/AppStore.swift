import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppStore {
    struct AuthenticationIssue: Equatable {
        let title: String
        let message: String
    }

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
    var spendingSnapshots: [SpendingSnapshot] = []
    var insightReport: InsightReport?
    var emailScanStatus: EmailScanStatus?
    var isLoadingEmailDiscovery = false
    var isReviewingEmailCandidate = false
    var emailCandidatePendingID: UUID?
    var isLoadingInsights = false
    var isLoadingInsightReport = false
    var isRefreshingInsights = false
    var hasLoadedInsightsData = false
    var insightsErrorMessage: String?
    var errorMessage: String?
    var authenticationIssue: AuthenticationIssue?
    var isBusy = false
    var isLoadingSubscriptions = false
    var hasLoadedSubscriptions = false
    var isRefreshingExchangeRates = false
    var exchangeRateErrorMessage: String?
    private var exchangeRateBaseCurrency: String?
    private var exchangeRates: [String: Decimal] = [:]
    private var sessionRefreshTask: Task<Session, Error>?

    private let sessionRefreshLeadTime: TimeInterval = 90

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
            !displayName.isEmpty
        {
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
            session = try JSONDecoder().decode(Session.self, from: data)
            _ = try await validAccessToken()
            try await refreshData()
            state = authenticatedDestination
        } catch {
            if session == nil {
                keychain.clear()
                state = .signedOut
                if errorMessage == nil {
                    errorMessage = error.localizedDescription
                }
            } else {
                state = authenticatedDestination
            }
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
        authenticationIssue = nil
        defer { isBusy = false }
        do {
            if createAccount {
                let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmedName.isEmpty else {
                    authenticationIssue = AuthenticationIssue(
                        title: "Add your name",
                        message: "Enter the name you would like us to use in Renewa."
                    )
                    return false
                }
                guard
                    let created = try await client.signUp(
                        email: email,
                        password: password,
                        displayName: trimmedName
                    )
                else {
                    authenticationIssue = AuthenticationIssue(
                        title: "Confirm your email",
                        message: "We sent a confirmation link to \(email). Open it, then return here to sign in."
                    )
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
            authenticationIssue = authenticationIssue(for: error, creatingAccount: createAccount)
            return false
        }
    }

    func googleAuthorization() throws -> OAuthAuthorization {
        try client.googleAuthorization()
    }

    func completeGoogleSignIn(callbackURL: URL, codeVerifier: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        authenticationIssue = nil
        defer { isBusy = false }
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            authenticationIssue = AuthenticationIssue(
                title: "Google sign-in didn’t finish",
                message: "Return to Renewa and try Google sign-in again."
            )
            return false
        }
        if let message = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            ?? components.queryItems?.first(where: { $0.name == "error" })?.value
        {
            authenticationIssue = AuthenticationIssue(
                title: "Google sign-in didn’t finish",
                message: message.humanReadableAuthenticationMessage
            )
            return false
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            authenticationIssue = AuthenticationIssue(
                title: "Google sign-in didn’t finish",
                message: "We didn’t receive a sign-in code. Please try again."
            )
            return false
        }
        do {
            session = try await client.exchangeGoogleAuthorizationCode(code, verifier: codeVerifier)
            try persistSession()
            try await refreshData()
            state = authenticatedDestination
            return true
        } catch {
            authenticationIssue = authenticationIssue(for: error, creatingAccount: false)
            return false
        }
    }

    func showGoogleAuthenticationIssue(_ error: Error) {
        authenticationIssue = authenticationIssue(for: error, creatingAccount: false)
    }

    func clearAuthenticationIssue() {
        authenticationIssue = nil
    }

    func signOut() async {
        if let accessToken = session?.accessToken {
            try? await client.signOut(accessToken: accessToken)
        }
        clearLocalSession()
    }

    func deleteAccount() async -> Bool {
        guard session != nil else {
            errorMessage = "Sign in to delete your account."
            return false
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await performAuthenticated { accessToken in
                try await self.client.deleteAccount(accessToken: accessToken)
            }
            clearLocalSession()
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func appDidBecomeActive() async {
        guard session != nil, state != .signedOut else { return }
        _ = try? await validAccessToken()
    }

    func refreshData() async throws {
        let isInitialLoad = !hasLoadedSubscriptions
        if isInitialLoad {
            isLoadingSubscriptions = true
        }
        defer {
            if isInitialLoad {
                isLoadingSubscriptions = false
            }
        }
        let values: ([Subscription], UserProfile) = try await performAuthenticated { accessToken in
            async let subscriptionsRequest = self.client.fetchSubscriptions(accessToken: accessToken)
            async let profileRequest = self.client.fetchProfile(accessToken: accessToken)
            return try await (subscriptionsRequest, profileRequest)
        }
        subscriptions = values.0
        profile = values.1
        hasLoadedSubscriptions = true
        await refreshExchangeRates()
    }

    func refreshSubscriptions() async throws {
        let isInitialLoad = !hasLoadedSubscriptions
        if isInitialLoad {
            isLoadingSubscriptions = true
        }
        defer {
            if isInitialLoad {
                isLoadingSubscriptions = false
            }
        }
        subscriptions = try await performAuthenticated { accessToken in
            try await self.client.fetchSubscriptions(accessToken: accessToken)
        }
        hasLoadedSubscriptions = true
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
        guard session != nil else { return false }
        do {
            let created = try await performAuthenticated { accessToken in
                try await self.client.createSubscription(subscription, accessToken: accessToken)
            }
            withAnimation(RenewaMotion.standard) {
                subscriptions.append(created)
                subscriptions.sort { $0.nextRenewalDate < $1.nextRenewalDate }
            }
            await refreshExchangeRates()
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func remove(_ subscription: Subscription) async -> Bool {
        guard session != nil else { return false }
        do {
            try await performAuthenticated { accessToken in
                try await self.client.deleteSubscription(id: subscription.id, accessToken: accessToken)
            }
            withAnimation(RenewaMotion.standard) {
                subscriptions.removeAll { $0.id == subscription.id }
            }
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func updateBrand(for subscription: Subscription, brandID: String?) async -> Bool {
        errorMessage = nil
        guard session != nil else { return false }
        do {
            let updated = try await performAuthenticated { accessToken in
                try await self.client.updateSubscriptionBrand(
                    id: subscription.id,
                    brandID: brandID,
                    accessToken: accessToken
                )
            }
            guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else {
                return false
            }
            withAnimation(RenewaMotion.quick) {
                subscriptions[index] = updated
            }
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func emailAuthorizationURL(provider: String) async throws -> URL {
        try await performAuthenticated { accessToken in
            try await self.client.mailAuthorizationURL(provider: provider, accessToken: accessToken)
        }
    }

    func loadEmailDiscovery() async {
        guard session != nil else { return }
        isLoadingEmailDiscovery = emailScanStatus == nil
        defer { isLoadingEmailDiscovery = false }
        do {
            let status = try await performAuthenticated { accessToken in
                try await self.client.emailScanStatus(scanID: nil, accessToken: accessToken)
            }
            withAnimation(RenewaMotion.quick) {
                emailScanStatus = status
            }
            if status.isActive {
                await pollEmailScan(id: status.scanID)
            }
        } catch {
            reportAuthenticatedOperationError(error)
        }
    }

    func startEmailScan() async -> Bool {
        guard session != nil else { return false }
        errorMessage = nil
        do {
            let status = try await performAuthenticated { accessToken in
                try await self.client.startEmailScan(accessToken: accessToken)
            }
            withAnimation(RenewaMotion.standard) {
                emailScanStatus = status
            }
            await pollEmailScan(id: status.scanID)
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func reviewEmailCandidate(
        _ candidate: EmailSubscriptionCandidate,
        decision: EmailCandidateDecision,
        edits: EmailCandidateEdits? = nil
    ) async -> Bool {
        guard session != nil else { return false }
        isReviewingEmailCandidate = true
        emailCandidatePendingID = candidate.id
        defer {
            isReviewingEmailCandidate = false
            emailCandidatePendingID = nil
        }
        do {
            _ = try await performAuthenticated { accessToken in
                try await self.client.reviewEmailCandidate(
                    id: candidate.id,
                    decision: decision,
                    edits: edits,
                    accessToken: accessToken
                )
            }
            let status = try await performAuthenticated { accessToken in
                try await self.client.emailScanStatus(
                    scanID: self.emailScanStatus?.scanID,
                    accessToken: accessToken
                )
            }
            withAnimation(RenewaMotion.standard) {
                emailScanStatus = status
            }
            if decision == .confirm {
                try await refreshSubscriptions()
            }
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func suppressEmailCandidate(_ candidate: EmailSubscriptionCandidate) async -> Bool {
        guard session != nil else { return false }
        isReviewingEmailCandidate = true
        emailCandidatePendingID = candidate.id
        defer {
            isReviewingEmailCandidate = false
            emailCandidatePendingID = nil
        }
        do {
            _ = try await performAuthenticated { accessToken in
                try await self.client.suppressEmailCandidate(id: candidate.id, accessToken: accessToken)
            }
            let status = try await performAuthenticated { accessToken in
                try await self.client.emailScanStatus(
                    scanID: self.emailScanStatus?.scanID,
                    accessToken: accessToken
                )
            }
            withAnimation(RenewaMotion.standard) {
                emailScanStatus = status
            }
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func unsuppressEmailMerchant(_ merchant: EmailMerchantSuppression) async -> Bool {
        guard session != nil else { return false }
        isReviewingEmailCandidate = true
        defer { isReviewingEmailCandidate = false }
        do {
            try await performAuthenticated { accessToken in
                try await self.client.unsuppressEmailMerchant(
                    canonicalMerchantKey: merchant.canonicalMerchantKey,
                    accessToken: accessToken
                )
            }
            await loadEmailDiscovery()
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func disconnectEmailConnection(_ connection: EmailConnectionSummary) async -> Bool {
        guard session != nil else { return false }
        do {
            _ = try await performAuthenticated { accessToken in
                try await self.client.disconnectEmailConnection(id: connection.id, accessToken: accessToken)
            }
            await loadEmailDiscovery()
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    func clearEmailScanHistory() async -> Bool {
        guard session != nil else { return false }
        do {
            try await performAuthenticated { accessToken in
                try await self.client.clearEmailScanHistory(accessToken: accessToken)
            }
            await loadEmailDiscovery()
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }

    private func pollEmailScan(id: UUID?) async {
        guard let id else { return }
        for _ in 0..<120 {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(for: .seconds(1))
                let status = try await performAuthenticated { accessToken in
                    try await self.client.emailScanStatus(scanID: id, accessToken: accessToken)
                }
                withAnimation(RenewaMotion.quick) {
                    emailScanStatus = status
                }
                if !status.isActive {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                reportAuthenticatedOperationError(error)
                return
            }
        }
    }

    func loadInsights(force: Bool = false) async {
        guard session != nil else { return }
        let isInitialDataLoad = !hasLoadedInsightsData
        if isInitialDataLoad {
            isLoadingInsights = true
        } else {
            isRefreshingInsights = true
        }
        if insightReport == nil {
            insightsErrorMessage = nil
        }
        do {
            let snapshots = try await performAuthenticated { accessToken in
                try await self.client.fetchSpendingSnapshots(accessToken: accessToken)
            }
            spendingSnapshots = snapshots
            await refreshExchangeRates()
        } catch {
            insightsErrorMessage = "Your spending history is unavailable right now."
        }
        hasLoadedInsightsData = true
        isLoadingInsights = false
        isLoadingInsightReport = true
        do {
            let response = try await performAuthenticated { accessToken in
                try await self.client.refreshInsights(force: force, accessToken: accessToken)
            }
            insightReport = response.report
        } catch {
            if insightReport == nil {
                insightsErrorMessage = "AI insights are unavailable right now. Your spending charts are still up to date."
            }
        }
        isLoadingInsightReport = false
        isRefreshingInsights = false
    }

    func convertedAmount(_ amount: Decimal, from sourceCurrency: String) -> Decimal? {
        let source = sourceCurrency.uppercased()
        let target = defaultCurrency.uppercased()
        if source == target {
            return amount
        }
        guard exchangeRateBaseCurrency == target,
            let rate = exchangeRates[source]
        else {
            return nil
        }
        return amount * rate
    }

    func convertedMonthlyCost(for subscription: Subscription) -> Decimal? {
        convertedAmount(subscription.monthlyCost, from: subscription.currency)
    }

    func convertedMonthlyCost(for snapshot: SpendingSnapshot) -> Decimal? {
        convertedAmount(snapshot.monthlyTotal, from: snapshot.currency)
    }

    private func refreshExchangeRates() async {
        let target = defaultCurrency.uppercased()
        let sourceCurrencies = Set(activeSubscriptions.map { $0.currency.uppercased() })
            .union(spendingSnapshots.map { $0.currency.uppercased() })
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

    private func performAuthenticated<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let accessToken = try await validAccessToken()
        do {
            return try await operation(accessToken)
        } catch {
            guard error.isAuthorizationFailure else { throw error }
            let refreshedAccessToken = try await validAccessToken(forceRefresh: true)
            return try await operation(refreshedAccessToken)
        }
    }

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let session else { throw APIError.notAuthenticated }
        guard forceRefresh || sessionNeedsRefresh(session) else {
            return session.accessToken
        }
        return try await refreshSession(using: session).accessToken
    }

    private func sessionNeedsRefresh(_ session: Session) -> Bool {
        guard let expiresAt = session.expiresAt else { return false }
        return expiresAt <= Date().timeIntervalSince1970 + sessionRefreshLeadTime
    }

    private func refreshSession(using currentSession: Session) async throws -> Session {
        if let sessionRefreshTask {
            return try await sessionRefreshTask.value
        }

        let refreshToken = currentSession.refreshToken
        let task = Task { [client] in
            try await client.refresh(using: refreshToken)
        }
        sessionRefreshTask = task
        defer { sessionRefreshTask = nil }

        do {
            let refreshed = try await task.value
            guard session?.refreshToken == refreshToken else {
                throw APIError.notAuthenticated
            }
            try keychain.save(JSONEncoder().encode(refreshed))
            session = refreshed
            return refreshed
        } catch {
            if error.isTerminalRefreshFailure {
                clearLocalSession(message: "Your session expired. Please sign in again.")
            }
            throw error
        }
    }

    private func clearLocalSession(message: String? = nil) {
        keychain.clear()
        session = nil
        profile = nil
        subscriptions = []
        spendingSnapshots = []
        insightReport = nil
        emailScanStatus = nil
        isLoadingEmailDiscovery = false
        isReviewingEmailCandidate = false
        emailCandidatePendingID = nil
        isLoadingInsights = false
        isLoadingInsightReport = false
        isRefreshingInsights = false
        hasLoadedInsightsData = false
        insightsErrorMessage = nil
        isLoadingSubscriptions = false
        hasLoadedSubscriptions = false
        exchangeRates = [:]
        exchangeRateBaseCurrency = nil
        exchangeRateErrorMessage = nil
        state = .signedOut
        errorMessage = message
    }

    private func reportAuthenticatedOperationError(_ error: Error) {
        if state != .signedOut {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticationIssue(for error: Error, creatingAccount: Bool) -> AuthenticationIssue {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return AuthenticationIssue(
                    title: "You’re offline",
                    message: "Check your internet connection, then try again."
                )
            case .timedOut:
                return AuthenticationIssue(
                    title: "This is taking too long",
                    message: "Renewa couldn’t reach the server. Please try again."
                )
            default:
                break
            }
        }

        if let apiError = error as? APIError, case .notConfigured = apiError {
            return AuthenticationIssue(
                title: "App setup is incomplete",
                message: "Renewa’s connection settings are missing. Please contact the app owner."
            )
        }

        let rawMessage = error.localizedDescription
        let normalized = rawMessage.lowercased()

        if normalized.contains("invalid login credentials") || normalized.contains("invalid credentials") {
            return AuthenticationIssue(
                title: "Email or password is incorrect",
                message: "Check both entries and try again, or create an account if you’re new to Renewa."
            )
        }
        if normalized.contains("email not confirmed") || normalized.contains("email confirmation") {
            return AuthenticationIssue(
                title: "Confirm your email first",
                message: "Open the confirmation link we sent you, then return here to sign in."
            )
        }
        if normalized.contains("already registered") || normalized.contains("already exists") {
            return AuthenticationIssue(
                title: "An account already exists",
                message: "Try signing in with this email instead."
            )
        }
        if normalized.contains("password") && (normalized.contains("weak") || normalized.contains("at least") || normalized.contains("short")) {
            return AuthenticationIssue(
                title: "Choose a stronger password",
                message: "Use at least 6 characters, then try again."
            )
        }
        if normalized.contains("rate limit") || normalized.contains("too many") {
            return AuthenticationIssue(
                title: "Please wait a moment",
                message: "There have been too many attempts. Wait a few minutes before trying again."
            )
        }
        if normalized.contains("signup") && normalized.contains("disabled") {
            return AuthenticationIssue(
                title: "Sign-up is unavailable",
                message: "New accounts are not available right now. Please try again later."
            )
        }
        if normalized.contains("email") && (normalized.contains("invalid") || normalized.contains("valid")) {
            return AuthenticationIssue(
                title: "Check your email address",
                message: "Enter a valid email address, then try again."
            )
        }

        return AuthenticationIssue(
            title: creatingAccount ? "We couldn’t create your account" : "We couldn’t sign you in",
            message: "Please try again in a moment. If this keeps happening, check your connection and try later."
        )
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
        guard !trimmedName.isEmpty, let userID = session?.user.id else {
            errorMessage = "Enter a display name before saving."
            return false
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            profile = try await performAuthenticated { accessToken in
                try await self.client.updateProfile(
                    id: userID,
                    displayName: trimmedName,
                    defaultCurrency: currency,
                    avatarKey: avatar.rawValue,
                    onboardingCompleted: onboardingCompleted,
                    accessToken: accessToken
                )
            }
            await refreshExchangeRates()
            if onboardingCompleted {
                state = .ready
            }
            return true
        } catch {
            reportAuthenticatedOperationError(error)
            return false
        }
    }
}

private extension Error {
    var isAuthorizationFailure: Bool {
        guard let apiError = self as? APIError,
            case let .server(status, _) = apiError
        else { return false }
        return status == 401
    }

    var isTerminalRefreshFailure: Bool {
        guard let apiError = self as? APIError,
            case let .server(status, _) = apiError
        else { return false }
        return [400, 401, 403].contains(status)
    }
}

private extension String {
    var humanReadableAuthenticationMessage: String {
        let normalized = lowercased()
        if normalized.contains("access_denied") || normalized.contains("access denied") {
            return "Google sign-in was cancelled or wasn’t allowed. Please try again when you’re ready."
        }
        if normalized.contains("redirect") {
            return "Google sign-in needs a valid return address. Please try again after checking the app’s sign-in setup."
        }
        return "Please return to Renewa and try Google sign-in again."
    }
}
