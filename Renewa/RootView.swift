import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch store.state {
            case .loading:
                LaunchView()
                    .transition(.opacity)
            case .configurationRequired:
                ConfigurationRequiredView()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
            case .signedOut:
                AuthView()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
            case .onboarding:
                OnboardingView()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .trailing))
                    )
            case .ready:
                MainTabView()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 1.015))
                    )
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.gentle, value: store.state)
        .tint(RenewaTheme.sage)
        .buttonStyle(PressScaleStyle())
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

private struct ConfigurationRequiredView: View {
    var body: some View {
        ZStack {
            RenewaTheme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                HeroIcon(.exclamationTriangle, size: 48)
                    .foregroundStyle(RenewaTheme.sage)
                Text("Backend configuration required")
                    .font(.renewa(24, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to Config.local.xcconfig, then rebuild the app.")
                    .font(.renewa(15))
                    .foregroundStyle(RenewaTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
        }
    }
}

private struct LaunchView: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RenewaTheme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(RenewaTheme.sage)
                        .frame(width: 64, height: 64)
                    HeroIcon(.arrowPath, size: 36)
                        .foregroundStyle(.white)
                }
                .scaleEffect(breathe ? 1.08 : 0.94)
                .rotationEffect(.degrees(breathe && !reduceMotion ? 10 : 0))
                Text("Renewa")
                    .font(.renewa(28, weight: .bold))
                    .opacity(breathe ? 1 : 0.62)
            }
        }
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .easeInOut(duration: 1).repeatForever(autoreverses: true)
            ) {
                breathe = true
            }
        }
    }
}

private enum AppTab: String, CaseIterable {
    case home
    case insights
    case inbox
    case profile

    var title: String {
        switch self {
        case .home: "Home"
        case .insights: "Insights"
        case .inbox: "Inbox"
        case .profile: "You"
        }
    }

    var icon: HeroIconName {
        switch self {
        case .home: .home
        case .insights: .chartBar
        case .inbox: .envelope
        case .profile: .userCircle
        }
    }

    /// Position in the tab bar, left to right. Drives the slide direction on a tab switch.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

struct MainTabView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedTab: AppTab = .home
    @State private var showingAdd = false
    @State private var prefilledSubscriptionName: String?
    /// True when the last switch moved to a tab further right, so the new screen slides
    /// in from the trailing edge; false slides it in from the leading edge.
    @State private var slideForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        #if DEBUG
            switch ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] {
            case "insights", "insights-empty", "insights-failure", "insights-inactive":
                _selectedTab = State(initialValue: .insights)
            case let screen? where screen.hasPrefix("inbox"):
                _selectedTab = State(initialValue: .inbox)
            case "profile":
                _selectedTab = State(initialValue: .profile)
            case "add":
                _showingAdd = State(initialValue: true)
            default:
                break
            }
        #endif
    }

    var body: some View {
        ZStack {
            Group {
                switch selectedTab {
                case .home:
                    NavigationStack {
                        if showsCalendarForQA {
                            PaymentCalendarView()
                        } else {
                            OverviewView(
                                onScanInbox: {
                                    selectTab(.inbox)
                                },
                                onAddSuggestion: { name in
                                    prefilledSubscriptionName = name
                                    showingAdd = true
                                }
                            )
                        }
                    }
                case .insights:
                    InsightsView(
                        onAddSubscription: {
                            showingAdd = true
                        },
                        onScanInbox: {
                            selectTab(.inbox)
                        }
                    )
                case .inbox:
                    EmailScanView(onAddManually: { showingAdd = true })
                case .profile: ProfileView()
                }
            }
            .id(selectedTab)
            .transition(reduceMotion ? .opacity : tabTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RenewaTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CustomTabBar(
                selectedTab: $selectedTab,
                showingAdd: $showingAdd,
                onTabSelected: selectTab
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $showingAdd, onDismiss: { prefilledSubscriptionName = nil }) {
            AddSubscriptionView(prefilledName: prefilledSubscriptionName)
                .presentationDetents([.large])
                .presentationCornerRadius(30)
        }
        .onReceive(NotificationCenter.default.publisher(for: .renewaOpenInboxIntelligence)) { _ in
            selectTab(.inbox)
            Task { await store.loadEmailDiscovery() }
        }
    }

    private var tabTransition: AnyTransition {
        // The incoming screen enters from the side we're heading toward; the outgoing one
        // exits the opposite side, so the two slide across together. A fade rounds off the
        // hand-off, and the bouncy spring in `selectTab` adds the slight settle at the end.
        let insertionEdge: Edge = slideForward ? .trailing : .leading
        let removalEdge: Edge = slideForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    private var showsCalendarForQA: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] == "calendar"
        #else
            false
        #endif
    }

    private func selectTab(_ tab: AppTab) {
        guard tab != selectedTab else { return }

        // Set the slide direction before the switch so `tabTransition` reads the right edges
        // for this render pass. Not wrapped in the animation — it just picks the transition.
        slideForward = tab.order > selectedTab.order

        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.bouncy) {
            selectedTab = tab
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab
    @Binding var showingAdd: Bool
    let onTabSelected: (AppTab) -> Void
    @Namespace private var activeIndicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                item(.home)
                item(.insights)
                Color.clear
                    .frame(width: 74)
                    .accessibilityHidden(true)
                item(.inbox)
                item(.profile)
            }
            .frame(height: 66)
            .padding(.horizontal, 8)
            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: RenewaTheme.ink.opacity(0.1), radius: 18, y: 8)
            .padding(.top, 20)

            Button {
                guard !showingAdd else { return }
                withAnimation(RenewaMotion.quick) {
                    showingAdd = true
                }
            } label: {
                HeroIcon(.plus, style: .solid, size: 29)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(RenewaTheme.sage, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(RenewaTheme.surface, lineWidth: 5)
                    }
                    .shadow(color: RenewaTheme.sage.opacity(0.28), radius: 16, y: 6)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Add subscription")
        }
        .frame(height: 86)
    }

    private func item(_ tab: AppTab) -> some View {
        Button {
            onTabSelected(tab)
        } label: {
            VStack(spacing: 4) {
                HeroIcon(
                    tab.icon,
                    style: selectedTab == tab ? .solid : .outline,
                    size: 24
                )
                .foregroundStyle(selectedTab == tab ? RenewaTheme.ink : RenewaTheme.muted.opacity(0.68))
                .scaleEffect(selectedTab == tab && !reduceMotion ? 1.1 : 1)

                Group {
                    if selectedTab == tab {
                        if reduceMotion {
                            Capsule()
                                .fill(RenewaTheme.sage)
                                .frame(width: 14, height: 3)
                                .transition(.opacity)
                        } else {
                            Capsule()
                                .fill(RenewaTheme.sage)
                                .frame(width: 14, height: 3)
                                .matchedGeometryEffect(id: "activeTabIndicator", in: activeIndicator)
                        }
                    } else {
                        Color.clear
                            .frame(width: 14, height: 3)
                    }
                }
            }
            .frame(height: 66)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}
