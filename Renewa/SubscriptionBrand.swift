import SwiftUI

struct SubscriptionBrand: Identifiable, Hashable {
    // A persisted, provider-independent choice that keeps automatic name lookup disabled for one row.
    static let fallbackOverrideID = "renewa-fallback"

    let id: String
    let displayName: String
    let logoDevDomain: String
    private let aliases: Set<String>

    static func resolve(_ name: String) -> SubscriptionBrand? {
        let normalized = normalize(name)
        return catalog.first { $0.aliases.contains(normalized) }
    }

    static func find(id: String?) -> SubscriptionBrand? {
        guard let id else { return nil }
        return catalog.first { $0.id == id }
    }

    static func isFallbackOverride(_ id: String?) -> Bool {
        id == fallbackOverrideID
    }

    static var reviewedBrands: [SubscriptionBrand] { catalog }

    static func normalizedAlias(for name: String) -> String {
        normalize(name)
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static let catalog: [SubscriptionBrand] = [
        .init(id: "netflix", displayName: "Netflix", logoDevDomain: "netflix.com", aliases: ["netflix", "netflixcom"]),
        .init(id: "spotify", displayName: "Spotify", logoDevDomain: "spotify.com", aliases: ["spotify", "spotifycom"]),
        .init(id: "notion", displayName: "Notion", logoDevDomain: "notion.so", aliases: ["notion", "notionso"]),
        .init(id: "dropbox", displayName: "Dropbox", logoDevDomain: "dropbox.com", aliases: ["dropbox", "dropboxcom", "dropboxplus"]),
        .init(id: "youtube", displayName: "YouTube", logoDevDomain: "youtube.com", aliases: ["youtube", "youtubepremium", "youtubecom"]),
        .init(id: "apple", displayName: "Apple", logoDevDomain: "apple.com", aliases: ["apple", "appleone", "icloud", "icloudplus", "applemusic", "appletv"]),
        .init(id: "google", displayName: "Google", logoDevDomain: "google.com", aliases: ["google", "googleone", "googleworkspace", "googlecom"]),
        .init(id: "discord", displayName: "Discord", logoDevDomain: "discord.com", aliases: ["discord", "discordnitro", "discordcom"]),
    ]
}

struct SubscriptionBrandIcon: View {
    let subscription: Subscription
    var size: CGFloat = 54

    var body: some View {
        let brand = SubscriptionBrand.find(id: subscription.brandID)
        let remoteURL: URL? = if SubscriptionBrand.isFallbackOverride(subscription.brandID) {
            nil
        } else {
            brand.flatMap { AppConfiguration.current.logoDevURL(forVerifiedDomain: $0.logoDevDomain) }
                ?? AppConfiguration.current.logoDevURL(forCompanyName: subscription.name)
        }
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(RenewaTheme.surface)

            if let remoteURL {
                AsyncImage(url: remoteURL, transaction: .init(animation: .easeInOut(duration: 0.18))) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: logoSize, height: logoSize)
                            .transition(.opacity)
                    } else {
                        fallbackMark
                    }
                }
            } else {
                fallbackMark
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.82), lineWidth: 1)
        }
        .shadow(color: RenewaTheme.ink.opacity(0.09), radius: size * 0.12, y: size * 0.06)
        .accessibilityLabel(subscription.name)
    }

    private var cornerRadius: CGFloat { min(size * 0.31, 18) }
    private var logoSize: CGFloat { size * 0.62 }

    private var fallbackMark: some View {
        Text(subscription.iconName)
            .font(.renewa(subscription.iconName.count > 1 ? size * 0.25 : size * 0.36, weight: .bold))
            .foregroundStyle(Color(hex: subscription.tintHex))
            .minimumScaleFactor(0.7)
            .frame(width: size * 0.62, height: size * 0.62)
            .background(
                Color(hex: subscription.tintHex).opacity(0.14),
                in: RoundedRectangle(cornerRadius: cornerRadius * 0.62, style: .continuous)
            )
    }
}
