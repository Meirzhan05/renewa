import CryptoKit
import Foundation
import Security

struct SupabaseClient {
    private let configuration: AppConfiguration
    private let session: URLSession

    init(configuration: AppConfiguration = .current, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func signIn(email: String, password: String) async throws -> Session {
        try await authRequest(
            path: "/auth/v1/token?grant_type=password",
            body: ["email": email, "password": password]
        )
    }

    func signUp(email: String, password: String, displayName: String) async throws -> Session? {
        let response: AuthEnvelope = try await request(
            path: "/auth/v1/signup",
            method: "POST",
            body: SignUpBody(email: email, password: password, data: .init(displayName: displayName)),
            accessToken: nil
        )
        return response.session
    }

    func googleAuthorization() throws -> OAuthAuthorization {
        guard let baseURL = configuration.supabaseURL else { throw APIError.notConfigured }
        let verifier = Self.base64URLEncoded(Self.randomBytes(count: 48))
        let challenge = Self.base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard var components = URLComponents(url: baseURL.appending(path: "auth/v1/authorize"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: "renewa://auth"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw APIError.invalidResponse }
        return OAuthAuthorization(url: url, codeVerifier: verifier)
    }

    func exchangeGoogleAuthorizationCode(_ code: String, verifier: String) async throws -> Session {
        try await authRequest(
            path: "/auth/v1/token?grant_type=pkce",
            body: ["auth_code": code, "code_verifier": verifier]
        )
    }

    func refresh(using refreshToken: String) async throws -> Session {
        try await authRequest(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": refreshToken]
        )
    }

    func signOut(accessToken: String) async throws {
        let request = try makeRequest(
            path: "/auth/v1/logout",
            method: "POST",
            accessToken: accessToken
        )
        try await performEmpty(request)
    }

    func deleteAccount(accessToken: String) async throws {
        let response: AccountDeletionResponse = try await request(
            path: "/functions/v1/delete-account",
            method: "POST",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard response.deleted else { throw APIError.invalidResponse }
    }

    func fetchSubscriptions(accessToken: String) async throws -> [Subscription] {
        try await request(
            path: "/rest/v1/subscriptions?select=*&order=next_renewal_date.asc",
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
    }

    func fetchProfile(accessToken: String) async throws -> UserProfile {
        let profiles: [UserProfile] = try await request(
            path: "/rest/v1/profiles?select=id,display_name,default_currency,avatar_key,onboarding_completed&limit=1",
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let profile = profiles.first else { throw APIError.invalidResponse }
        return profile
    }

    func updateProfile(
        id: UUID,
        displayName: String,
        defaultCurrency: String,
        avatarKey: String,
        onboardingCompleted: Bool,
        accessToken: String
    ) async throws -> UserProfile {
        var request = try makeRequest(
            path: "/rest/v1/profiles?id=eq.\(id.uuidString)",
            method: "PATCH",
            accessToken: accessToken
        )
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.encoder.encode(
            ProfileUpdate(
                displayName: displayName,
                defaultCurrency: defaultCurrency,
                avatarKey: avatarKey,
                onboardingCompleted: onboardingCompleted
            )
        )
        let profiles: [UserProfile] = try await perform(request)
        guard let profile = profiles.first else { throw APIError.invalidResponse }
        return profile
    }

    func createSubscription(_ subscription: Subscription, accessToken: String) async throws -> Subscription {
        var request = try makeRequest(
            path: "/rest/v1/subscriptions",
            method: "POST",
            accessToken: accessToken
        )
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.encoder.encode(SubscriptionInsert(subscription))
        let values: [Subscription] = try await perform(request)
        guard let created = values.first else { throw APIError.invalidResponse }
        return created
    }

    func updateSubscriptionBrand(
        id: UUID,
        brandID: String?,
        accessToken: String
    ) async throws -> Subscription {
        var request = try makeRequest(
            path: "/rest/v1/subscriptions?id=eq.\(id.uuidString)",
            method: "PATCH",
            accessToken: accessToken
        )
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.encoder.encode(SubscriptionBrandUpdate(brandID: brandID))
        let values: [Subscription] = try await perform(request)
        guard let updated = values.first else { throw APIError.invalidResponse }
        return updated
    }

    func deleteSubscription(id: UUID, accessToken: String) async throws {
        let request = try makeRequest(
            path: "/rest/v1/subscriptions?id=eq.\(id.uuidString)",
            method: "DELETE",
            accessToken: accessToken
        )
        try await performEmpty(request)
    }

    func startEmailScan(accessToken: String) async throws -> EmailScanStatus {
        try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: EmailScanRequest(action: "start", days: 365, scanID: nil),
            accessToken: accessToken
        )
    }

    func emailScanStatus(scanID: UUID?, accessToken: String) async throws -> EmailScanStatus {
        try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: EmailScanRequest(action: "status", days: nil, scanID: scanID),
            accessToken: accessToken
        )
    }

    func reviewEmailCandidate(
        id: UUID,
        decision: EmailCandidateDecision,
        edits: EmailCandidateEdits?,
        accessToken: String
    ) async throws -> EmailCandidateDecisionResponse {
        try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: EmailCandidateReviewRequest(
                action: "review",
                candidateID: id,
                decision: decision.rawValue,
                edits: edits.map(CandidateEditBody.init)
            ),
            accessToken: accessToken
        )
    }

    func suppressEmailCandidate(
        id: UUID,
        accessToken: String
    ) async throws -> EmailCandidateDecisionResponse {
        try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: EmailCandidateSuppressRequest(action: "suppress", candidateID: id),
            accessToken: accessToken
        )
    }

    func unsuppressEmailMerchant(
        canonicalMerchantKey: String,
        accessToken: String
    ) async throws {
        let response: EmailMerchantUnsuppressionResponse = try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: EmailMerchantUnsuppressionRequest(
                action: "unsuppress",
                canonicalMerchantKey: canonicalMerchantKey
            ),
            accessToken: accessToken
        )
        guard response.unsuppressed else { throw APIError.invalidResponse }
    }

    func disconnectEmailConnection(id: UUID, accessToken: String) async throws -> EmailDisconnectResponse {
        try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: EmailDisconnectRequest(action: "disconnect", connectionID: id),
            accessToken: accessToken
        )
    }

    func clearEmailScanHistory(accessToken: String) async throws {
        let response: EmailHistoryCleanupResponse = try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: ["action": "clear_history"],
            accessToken: accessToken
        )
        guard response.cleared else { throw APIError.invalidResponse }
    }

    func fetchSpendingSnapshots(accessToken: String) async throws -> [SpendingSnapshot] {
        try await request(
            path: "/rest/v1/monthly_spend_snapshots?select=id,period_start,currency,monthly_total,category_totals&order=period_start.asc",
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
    }

    func refreshInsights(force: Bool, accessToken: String) async throws -> InsightRefreshResponse {
        try await request(
            path: "/functions/v1/insights-refresh",
            method: "POST",
            body: ["force": force],
            accessToken: accessToken
        )
    }

    func mailAuthorizationURL(provider: String, accessToken: String) async throws -> URL {
        let response: AuthorizationURLResponse = try await request(
            path: "/functions/v1/mail-oauth-start",
            method: "POST",
            body: ["provider": provider],
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else { throw APIError.invalidResponse }
        return url
    }

    private func authRequest(path: String, body: [String: String]) async throws -> Session {
        let envelope: AuthEnvelope = try await request(
            path: path,
            method: "POST",
            body: body,
            accessToken: nil
        )
        guard let session = envelope.session else { throw APIError.emailConfirmationRequired }
        return session
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        accessToken: String?
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, accessToken: accessToken)
        if let body {
            request.httpBody = try Self.encoder.encode(body)
        }
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func performEmpty(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func makeRequest(path: String, method: String, accessToken: String?) throws -> URLRequest {
        guard let baseURL = configuration.supabaseURL,
            let url = URL(string: path, relativeTo: baseURL)
        else {
            throw APIError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? configuration.publishableKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard 200..<300 ~= response.statusCode else {
            let envelope = try? Self.decoder.decode(ErrorEnvelope.self, from: data)
            let message =
                envelope?.message ?? envelope?.errorDescription
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw APIError.server(status: response.statusCode, message: message)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            let day = DateFormatter()
            day.calendar = Calendar(identifier: .iso8601)
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            if let date = day.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date.")
        }
        return decoder
    }()

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            return Data(UUID().uuidString.utf8)
        }
        return Data(bytes)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct OAuthAuthorization {
    let url: URL
    let codeVerifier: String
}

private struct AuthEnvelope: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresAt: TimeInterval?
    let user: AuthUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case user
    }

    var session: Session? {
        guard let accessToken, let refreshToken, let user else { return nil }
        return Session(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, user: user)
    }
}

private struct AuthorizationURLResponse: Decodable {
    let url: String
}

private struct AccountDeletionResponse: Decodable {
    let deleted: Bool
}

enum EmailCandidateDecision: String, Equatable {
    case confirm
    case ignore
}

private struct EmailScanRequest: Encodable {
    let action: String
    let days: Int?
    let scanID: UUID?

    enum CodingKeys: String, CodingKey {
        case action
        case days
        case scanID = "scan_id"
    }
}

private struct EmailCandidateReviewRequest: Encodable {
    let action: String
    let candidateID: UUID
    let decision: String
    let edits: CandidateEditBody?

    enum CodingKeys: String, CodingKey {
        case action
        case candidateID = "candidate_id"
        case decision
        case edits
    }
}

private struct EmailCandidateSuppressRequest: Encodable {
    let action: String
    let candidateID: UUID

    enum CodingKeys: String, CodingKey {
        case action
        case candidateID = "candidate_id"
    }
}

private struct EmailMerchantUnsuppressionRequest: Encodable {
    let action: String
    let canonicalMerchantKey: String

    enum CodingKeys: String, CodingKey {
        case action
        case canonicalMerchantKey = "canonical_merchant_key"
    }
}

private struct EmailMerchantUnsuppressionResponse: Decodable {
    let unsuppressed: Bool
}

private struct CandidateEditBody: Encodable {
    let merchantName: String
    let amount: Decimal?
    let currency: String
    let billingCycle: BillingCycle
    let renewalDate: String
    let category: SubscriptionCategory

    init(_ edits: EmailCandidateEdits) {
        merchantName = edits.merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        amount = edits.amount
        currency = edits.currency.uppercased()
        billingCycle = edits.billingCycle
        renewalDate = Self.dayFormatter.string(from: edits.renewalDate)
        category = edits.category
    }

    enum CodingKeys: String, CodingKey {
        case merchantName = "merchant_name"
        case amount
        case currency
        case billingCycle = "billing_cycle"
        case renewalDate = "renewal_date"
        case category
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct EmailDisconnectRequest: Encodable {
    let action: String
    let connectionID: UUID

    enum CodingKeys: String, CodingKey {
        case action
        case connectionID = "connection_id"
    }
}

private struct EmailHistoryCleanupResponse: Decodable {
    let cleared: Bool
}

private struct SignUpBody: Encodable {
    struct Metadata: Encodable {
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    let email: String
    let password: String
    let data: Metadata
}

private struct ProfileUpdate: Encodable {
    let displayName: String
    let defaultCurrency: String
    let avatarKey: String
    let onboardingCompleted: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case defaultCurrency = "default_currency"
        case avatarKey = "avatar_key"
        case onboardingCompleted = "onboarding_completed"
    }
}

private struct SubscriptionInsert: Encodable {
    let name: String
    let price: Decimal
    let currency: String
    let billingCycle: BillingCycle
    let nextRenewalDate: Date
    let category: SubscriptionCategory
    let status: SubscriptionStatus
    let iconName: String
    let brandID: String?
    let tintHex: String
    let source: String

    init(_ subscription: Subscription) {
        name = subscription.name
        price = subscription.price
        currency = subscription.currency
        billingCycle = subscription.billingCycle
        nextRenewalDate = subscription.nextRenewalDate
        category = subscription.category
        status = subscription.status
        iconName = subscription.iconName
        brandID = subscription.brandID
        tintHex = subscription.tintHex
        source = subscription.source
    }

    enum CodingKeys: String, CodingKey {
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
    }
}

private struct SubscriptionBrandUpdate: Encodable {
    let brandID: String?

    enum CodingKeys: String, CodingKey {
        case brandID = "brand_id"
    }
}

private struct ErrorEnvelope: Decodable {
    let message: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case message
        case errorDescription = "error_description"
    }
}

enum APIError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidResponse
    case emailConfirmationRequired
    case decoding(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Supabase URL and publishable key to Config.local.xcconfig."
        case .notAuthenticated: "Sign in to continue."
        case .invalidResponse: "The server returned an invalid response."
        case .emailConfirmationRequired: "Check your inbox to confirm your email, then sign in."
        case let .decoding(detail): "Could not read the server response: \(detail)"
        case let .server(_, message): message
        }
    }
}
