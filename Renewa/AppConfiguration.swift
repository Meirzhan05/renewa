import Foundation

struct AppConfiguration: Sendable {
    let supabaseURL: URL?
    let publishableKey: String
    let logoDevPublishableKey: String

    static let current = AppConfiguration(
        supabaseURL: {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
                  !raw.isEmpty else { return nil }
            return URL(string: raw)
        }(),
        publishableKey: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? "",
        logoDevPublishableKey: Bundle.main.object(forInfoDictionaryKey: "LOGO_DEV_PUBLISHABLE_KEY") as? String ?? ""
    )

    var isConfigured: Bool {
        supabaseURL?.host != nil && !publishableKey.isEmpty
    }

    var hasLogoDevPublishableKey: Bool {
        logoDevPublishableKey.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pk_")
    }

    func logoDevURL(forVerifiedDomain domain: String) -> URL? {
        logoDevURL(pathPrefix: nil, identifier: domain)
    }

    func logoDevURL(forCompanyName name: String) -> URL? {
        logoDevURL(pathPrefix: "name", identifier: name)
    }

    private func logoDevURL(pathPrefix: String?, identifier: String) -> URL? {
        let key = logoDevPublishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasLogoDevPublishableKey, !identifier.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "img.logo.dev"
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedIdentifier = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        components.percentEncodedPath = pathPrefix.map { "/\($0)/\(encodedIdentifier)" } ?? "/\(encodedIdentifier)"
        components.queryItems = [
            URLQueryItem(name: "token", value: key),
            URLQueryItem(name: "size", value: "160"),
            URLQueryItem(name: "format", value: "png"),
            URLQueryItem(name: "theme", value: "light"),
            URLQueryItem(name: "retina", value: "true"),
            URLQueryItem(name: "fallback", value: "404"),
            URLQueryItem(name: "v", value: "brand-stamp-1"),
        ]
        return components.url
    }

    var localDebugCredentials: (email: String, password: String)? {
#if DEBUG
        guard supabaseURL?.host == "127.0.0.1" || supabaseURL?.host == "localhost" else {
            return nil
        }
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["RENEWA_QA_EMAIL"],
              let password = environment["RENEWA_QA_PASSWORD"],
              !email.isEmpty,
              !password.isEmpty else {
            return nil
        }
        return (email, password)
#else
        return nil
#endif
    }
}
