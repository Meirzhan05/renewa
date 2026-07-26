import SwiftUI

struct SubscriptionBrand: Identifiable, Hashable {
    let id: String
    let displayName: String
    let assetName: String
    let logoDevDomain: String
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
        .init(id: "netflix", displayName: "Netflix", assetName: "Brand-Netflix", logoDevDomain: "netflix.com", background: Color(hex: "#E50914"), foreground: .white, border: nil, aliases: ["netflix", "netflixcom"]),
        .init(id: "spotify", displayName: "Spotify", assetName: "Brand-Spotify", logoDevDomain: "spotify.com", background: Color(hex: "#1DB954"), foreground: .black, border: nil, aliases: ["spotify", "spotifycom"]),
        .init(id: "notion", displayName: "Notion", assetName: "Brand-Notion", logoDevDomain: "notion.so", background: .white, foreground: .black, border: RenewaTheme.ink.opacity(0.12), aliases: ["notion", "notionso"]),
        .init(id: "dropbox", displayName: "Dropbox", assetName: "Brand-Dropbox", logoDevDomain: "dropbox.com", background: Color(hex: "#0061FF"), foreground: .white, border: nil, aliases: ["dropbox", "dropboxcom", "dropboxplus"]),
        .init(id: "youtube", displayName: "YouTube", assetName: "Brand-YouTube", logoDevDomain: "youtube.com", background: Color(hex: "#FF0000"), foreground: .white, border: nil, aliases: ["youtube", "youtubepremium", "youtubecom"]),
        .init(id: "apple", displayName: "Apple", assetName: "Brand-Apple", logoDevDomain: "apple.com", background: .black, foreground: .white, border: nil, aliases: ["apple", "appleone", "icloud", "icloudplus", "applemusic", "appletv"]),
        .init(id: "google", displayName: "Google", assetName: "Brand-Google", logoDevDomain: "google.com", background: .white, foreground: Color(hex: "#4285F4"), border: RenewaTheme.ink.opacity(0.12), aliases: ["google", "googleone", "googleworkspace", "googlecom"]),
        .init(id: "discord", displayName: "Discord", assetName: "Brand-Discord", logoDevDomain: "discord.com", background: Color(hex: "#5865F2"), foreground: .white, border: nil, aliases: ["discord", "discordnitro", "discordcom"]),
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
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(remoteURL == nil ? (brand?.background ?? Color(hex: subscription.tintHex)) : .white)

            if let remoteURL {
                AsyncImage(url: remoteURL, transaction: .init(animation: .easeInOut(duration: 0.18))) { phase in
                    if case let .success(image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.1)
                            .transition(.opacity)
                    } else {
                        localFallback(for: brand)
                    }
                }
            } else {
                localFallback(for: brand)
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

    @ViewBuilder
    private func localFallback(for brand: SubscriptionBrand?) -> some View {
        if let brand {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(brand.background)
                .overlay {
                    Image(brand.assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(brand.foreground)
                        .padding(size * 0.24)
                }
                .overlay {
                    if let border = brand.border {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(border, lineWidth: 1)
                    }
                }
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Text(subscription.iconName)
            .font(.renewa(subscription.iconName.count > 1 ? size * 0.28 : size * 0.39, weight: .bold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.7)
    }
}
