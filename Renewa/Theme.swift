import SwiftUI

enum RenewaTheme {
    static let background = Color(red: 0.937, green: 0.925, blue: 0.886)
    static let surface = Color(red: 0.973, green: 0.961, blue: 0.929)
    static let ink = Color(red: 0.129, green: 0.118, blue: 0.094)
    static let muted = Color(red: 0.436, green: 0.408, blue: 0.345)
    static let divider = Color(red: 0.87, green: 0.83, blue: 0.73)
    static let sage = Color(red: 0.357, green: 0.541, blue: 0.447)
    static let sageLight = Color(red: 0.77, green: 0.84, blue: 0.71)
    static let sand = Color(red: 0.84, green: 0.77, blue: 0.62)
    static let coral = Color(red: 0.694, green: 0.475, blue: 0.353)

    /// The lightest ink on sand: labels, units, and the trailing half of a metadata line.
    static let mutedSoft = Color(red: 0.659, green: 0.620, blue: 0.545)
    /// Hairline used to split the inside of a card, a shade lighter than `divider`.
    static let hairline = Color(red: 0.929, green: 0.906, blue: 0.851)
    /// Unfilled portion of a progress track sitting on `surface`.
    static let track = Color(red: 0.914, green: 0.890, blue: 0.831)
    /// Warning ink for a renewal that lands inside the next week.
    static let clay = Color(red: 0.639, green: 0.400, blue: 0.247)
    /// Tint behind `clay` — badges and urgent chips.
    static let clayTint = Color(red: 0.949, green: 0.886, blue: 0.839)

    /// The middle rung of the ink ladder: `ink` → `muted` → `mutedBody` → `mutedSoft`.
    /// Secondary prose that should stay readable without competing with a heading.
    static let mutedBody = Color(red: 0.541, green: 0.510, blue: 0.447)
    /// Ink for money the reader gets back, a shade deeper than `sage` so it holds at small sizes.
    static let positive = Color(red: 0.247, green: 0.478, blue: 0.353)
    /// Tint behind `sage` — the quiet counterpart to `clayTint`.
    static let sageTint = Color(red: 0.902, green: 0.937, blue: 0.902)
}

enum RenewaMotion {
    static let quick = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let standard = Animation.spring(response: 0.52, dampingFraction: 0.84)
    static let gentle = Animation.spring(response: 0.72, dampingFraction: 0.88)
    /// Directional slide with a slight overshoot at the end (used for tab switches).
    /// The low damping is what produces the little bounce as the incoming view settles.
    static let bouncy = Animation.spring(response: 0.44, dampingFraction: 0.74)
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
    let motion: Animation

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : distance)
            .scaleEffect(isVisible || reduceMotion ? 1 : 0.985)
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : motion.delay(delay),
                value: isVisible
            )
    }
}

extension View {
    /// Fades and lifts a section into place. `motion` defaults to the unhurried curve a root screen
    /// arrives on; a sheet that already animates itself in passes a shorter one, so its own
    /// presentation is not left racing the content inside it.
    func renewaEntrance(
        _ isVisible: Bool,
        delay: Double = 0,
        distance: CGFloat = 16,
        motion: Animation = RenewaMotion.gentle
    ) -> some View {
        modifier(
            RenewaEntranceModifier(
                isVisible: isVisible,
                delay: delay,
                distance: distance,
                motion: motion
            )
        )
    }
}
