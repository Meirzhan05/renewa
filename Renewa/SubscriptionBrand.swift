import SwiftUI

struct SubscriptionBrand: Identifiable, Hashable {
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
    var cornerRadius: CGFloat = 16

    var body: some View {
        let brand = SubscriptionBrand.find(id: subscription.brandID)
        let remoteURL = brand.map { AppConfiguration.current.logoDevURL(forDomain: $0.logoDevDomain) }
            ?? AppConfiguration.current.logoDevURL(forCompanyName: subscription.name)
        ZStack {
            if let remoteURL {
                AsyncImage(url: remoteURL, transaction: .init(animation: .easeInOut(duration: 0.18))) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.1)
                            .transition(.opacity)
                    } else {
                        fallbackTile
                    }
                }
            } else {
                fallbackTile
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(subscription.name)
    }

    private var fallbackTile: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(hex: subscription.tintHex))
            .overlay {
                Text(subscription.iconName)
                    .font(.renewa(subscription.iconName.count > 1 ? size * 0.28 : size * 0.39, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
            }
    }
}
