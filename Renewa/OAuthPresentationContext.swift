import AuthenticationServices
import UIKit

@MainActor
final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return activeScene?.windows.first(where: { $0.isKeyWindow })
            ?? activeScene?.windows.first
            ?? ASPresentationAnchor()
    }
}
