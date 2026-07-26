import SwiftUI

struct SubscriptionBrand: Identifiable, Hashable {
    let id: String
    let displayName: String
    let assetName: String
    let background: Color
    let foreground: Color
    let border: Color?
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
        .init(id: "netflix", displayName: "Netflix", assetName: "Brand-Netflix", background: Color(hex: "#E50914"), foreground: .white, border: nil, aliases: ["netflix", "netflixcom"]),
        .init(id: "spotify", displayName: "Spotify", assetName: "Brand-Spotify", background: Color(hex: "#1DB954"), foreground: .black, border: nil, aliases: ["spotify", "spotifycom"]),
        .init(id: "notion", displayName: "Notion", assetName: "Brand-Notion", background: .white, foreground: .black, border: RenewaTheme.ink.opacity(0.12), aliases: ["notion", "notionso"]),
        .init(id: "dropbox", displayName: "Dropbox", assetName: "Brand-Dropbox", background: Color(hex: "#0061FF"), foreground: .white, border: nil, aliases: ["dropbox", "dropboxcom", "dropboxplus"]),
        .init(id: "youtube", displayName: "YouTube", assetName: "Brand-YouTube", background: Color(hex: "#FF0000"), foreground: .white, border: nil, aliases: ["youtube", "youtubepremium", "youtubecom"]),
        .init(id: "apple", displayName: "Apple", assetName: "Brand-Apple", background: .black, foreground: .white, border: nil, aliases: ["apple", "appleone", "icloud", "icloudplus", "applemusic", "appletv"]),
        .init(id: "google", displayName: "Google", assetName: "Brand-Google", background: .white, foreground: Color(hex: "#4285F4"), border: RenewaTheme.ink.opacity(0.12), aliases: ["google", "googleone", "googleworkspace", "googlecom"]),
        .init(id: "discord", displayName: "Discord", assetName: "Brand-Discord", background: Color(hex: "#5865F2"), foreground: .white, border: nil, aliases: ["discord", "discordnitro", "discordcom"]),
    ]
}

struct SubscriptionBrandIcon: View {
    let subscription: Subscription
    var size: CGFloat = 54
    var cornerRadius: CGFloat = 16

    var body: some View {
        let brand = SubscriptionBrand.find(id: subscription.brandID)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(brand?.background ?? Color(hex: subscription.tintHex))

            if let brand {
                Image(brand.assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(brand.foreground)
                    .padding(size * 0.24)
            } else {
                Text(subscription.iconName)
                    .font(.renewa(subscription.iconName.count > 1 ? size * 0.28 : size * 0.39, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
            }
        }
        .overlay {
            if let border = brand?.border {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(subscription.name)
    }
}
