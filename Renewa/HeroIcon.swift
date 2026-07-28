import SwiftUI

enum HeroIconName: String {
    case academicCap = "academic-cap"
    case arrowPath = "arrow-path"
    case arrowRightStartOnRectangle = "arrow-right-start-on-rectangle"
    case briefcase
    case calendar
    case camera
    case chartBar = "chart-bar"
    case checkCircle = "check-circle"
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case cloud
    case currencyDollar = "currency-dollar"
    case envelope
    case exclamationTriangle = "exclamation-triangle"
    case heart
    case home
    case lightBulb = "light-bulb"
    case lockClosed = "lock-closed"
    case plus
    case rectangleStack = "rectangle-stack"
    case sparkles
    case trash
    case user
    case userCircle = "user-circle"
}

enum HeroIconStyle: String {
    case outline
    case solid
}

struct HeroIcon: View {
    let name: HeroIconName
    let style: HeroIconStyle
    let size: CGFloat

    init(_ name: HeroIconName, style: HeroIconStyle = .outline, size: CGFloat = 24) {
        self.name = name
        self.style = style
        self.size = size
    }

    var body: some View {
        Image("Hero-\(name.rawValue)-\(resolvedStyle.rawValue)")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private var resolvedStyle: HeroIconStyle {
        switch (name, style) {
        case (.chartBar, .solid),
             (.checkCircle, .solid),
             (.envelope, .solid),
             (.home, .solid),
             (.plus, .solid),
             (.sparkles, .solid),
             (.userCircle, .solid):
            .solid
        default:
            .outline
        }
    }
}
