import SwiftUI

enum RenewaTheme {
    static let background = Color(red: 0.965, green: 0.947, blue: 0.902)
    static let surface = Color(red: 0.985, green: 0.974, blue: 0.944)
    static let ink = Color(red: 0.105, green: 0.094, blue: 0.078)
    static let muted = Color(red: 0.49, green: 0.46, blue: 0.39)
    static let divider = Color(red: 0.87, green: 0.83, blue: 0.73)
    static let sage = Color(red: 0.35, green: 0.59, blue: 0.49)
    static let sageLight = Color(red: 0.77, green: 0.84, blue: 0.71)
    static let sand = Color(red: 0.84, green: 0.77, blue: 0.62)
    static let coral = Color(red: 0.72, green: 0.43, blue: 0.31)
}

enum RenewaMotion {
    static let quick = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let standard = Animation.spring(response: 0.52, dampingFraction: 0.84)
    static let gentle = Animation.spring(response: 0.72, dampingFraction: 0.88)
}

extension Font {
    static func renewa(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.945 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(reduceMotion ? nil : RenewaMotion.quick, value: configuration.isPressed)
    }
}

struct RenewaCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.62), lineWidth: 1)
            }
    }
}

struct RenewaSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShimmering = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        RenewaTheme.divider.opacity(0.30),
                        RenewaTheme.surface.opacity(0.96),
                        RenewaTheme.divider.opacity(0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, RenewaTheme.sageLight.opacity(0.34), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(proxy.size.width * 0.62, 86))
                    .offset(x: isShimmering ? proxy.size.width : -max(proxy.size.width * 0.62, 86))
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.68), lineWidth: 1)
            }
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 1.35).repeatForever(autoreverses: false),
                value: isShimmering
            )
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                isShimmering = false
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                isShimmering = true
            }
    }
}

struct RenewaDelayedSkeleton<Content: View>: View {
    let accessibilityLabel: String
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    init(
        accessibilityLabel: String,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHidden(!isVisible)
            .task {
                isVisible = false
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    isVisible = true
                }
            }
    }
}

struct RenewaPrimaryActionLabel: View {
    let title: String
    let pendingTitle: String
    let isPending: Bool
    var icon: HeroIconName?

    var body: some View {
        HStack(spacing: 10) {
            if !isPending, let icon {
                HeroIcon(icon, style: .solid, size: 20)
            }
            Text(isPending ? pendingTitle : title)
                .contentTransition(.opacity)
        }
        .accessibilityLabel(isPending ? pendingTitle : title)
    }
}

private struct RenewaEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isVisible: Bool
    let delay: Double
    let distance: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : distance)
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.985)
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.gentle.delay(delay),
                value: isVisible
            )
    }
}

extension View {
    func renewaEntrance(
        _ isVisible: Bool,
        delay: Double = 0,
        distance: CGFloat = 16
    ) -> some View {
        modifier(RenewaEntranceModifier(isVisible: isVisible, delay: delay, distance: distance))
    }
}
