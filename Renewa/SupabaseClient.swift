import Foundation

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

    func signUp(email: String, password: String) async throws -> Session? {
        let response: AuthEnvelope = try await request(
            path: "/auth/v1/signup",
            method: "POST",
            body: ["email": email, "password": password],
            accessToken: nil
        )
        return response.session
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
            path: "/rest/v1/profiles?select=id,display_name,default_currency&limit=1",
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
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

    func deleteSubscription(id: UUID, accessToken: String) async throws {
        let request = try makeRequest(
            path: "/rest/v1/subscriptions?id=eq.\(id.uuidString)",
            method: "DELETE",
            accessToken: accessToken
        )
        try await performEmpty(request)
    }

    func scanEmail(accessToken: String) async throws -> EmailScanResult {
        try await request(
            path: "/functions/v1/email-scan",
            method: "POST",
            body: ["days": 365],
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
              let url = URL(string: path, relativeTo: baseURL) else {
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
            let message = (try? Self.decoder.decode(ErrorEnvelope.self, from: data).message)
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

private struct SubscriptionInsert: Encodable {
    let name: String
    let price: Decimal
    let currency: String
    let billingCycle: BillingCycle
    let nextRenewalDate: Date
    let category: SubscriptionCategory
    let status: SubscriptionStatus
    let iconName: String
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
        case tintHex = "tint_hex"
        case source
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
    case invalidResponse
    case emailConfirmationRequired
    case decoding(String)
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Supabase URL and publishable key to Config.local.xcconfig."
        case .invalidResponse: "The server returned an invalid response."
        case .emailConfirmationRequired: "Check your inbox to confirm your email, then sign in."
        case let .decoding(detail): "Could not read the server response: \(detail)"
        case let .server(_, message): message
        }
    }
}
