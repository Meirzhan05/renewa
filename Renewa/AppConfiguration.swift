import Foundation

struct AppConfiguration: Sendable {
    let supabaseURL: URL?
    let publishableKey: String

    static let current = AppConfiguration(
        supabaseURL: {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
                  !raw.isEmpty else { return nil }
            return URL(string: raw)
        }(),
        publishableKey: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""
    )

    var isConfigured: Bool {
        supabaseURL != nil && !publishableKey.isEmpty
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
