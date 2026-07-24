import SwiftUI

struct SubscriptionBrand: Identifiable, Hashable {
    let id: String
    let displayName: String
    let assetName: String
    let tint: Color
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
        .init(id: "netflix", displayName: "Netflix", assetName: "Brand-Netflix", tint: .red, aliases: ["netflix", "netflixcom"]),
        .init(id: "spotify", displayName: "Spotify", assetName: "Brand-Spotify", tint: Color(red: 0.11, green: 0.72, blue: 0.33), aliases: ["spotify", "spotifycom"]),
        .init(id: "notion", displayName: "Notion", assetName: "Brand-Notion", tint: RenewaTheme.ink, aliases: ["notion", "notionso"]),
        .init(id: "dropbox", displayName: "Dropbox", assetName: "Brand-Dropbox", tint: Color(red: 0.0, green: 0.38, blue: 1.0), aliases: ["dropbox", "dropboxcom", "dropboxplus"]),
        .init(id: "youtube", displayName: "YouTube", assetName: "Brand-YouTube", tint: .red, aliases: ["youtube", "youtubepremium", "youtubecom"]),
        .init(id: "apple", displayName: "Apple", assetName: "Brand-Apple", tint: RenewaTheme.ink, aliases: ["apple", "appleone", "icloud", "icloudplus", "applemusic", "appletv"]),
        .init(id: "google", displayName: "Google", assetName: "Brand-Google", tint: Color(red: 0.26, green: 0.52, blue: 0.96), aliases: ["google", "googleone", "googleworkspace", "googlecom"]),
        .init(id: "discord", displayName: "Discord", assetName: "Brand-Discord", tint: Color(red: 0.35, green: 0.40, blue: 0.95), aliases: ["discord", "discordnitro", "discordcom"]),
    ]
}

struct SubscriptionBrandIcon: View {
    let subscription: Subscription
    var size: CGFloat = 54
    var cornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(hex: subscription.tintHex))

            if let brand = SubscriptionBrand.find(id: subscription.brandID) {
                Image(brand.assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(brand.tint)
                    .padding(size * 0.24)
            } else {
                Text(subscription.iconName)
                    .font(.renewa(subscription.iconName.count > 1 ? size * 0.28 : size * 0.39, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(subscription.name)
    }
}
