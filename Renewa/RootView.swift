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
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 48, weight: .medium))
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
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(RenewaTheme.sage)
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

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .insights: "chart.bar.xaxis"
        case .inbox: "envelope.badge"
        case .profile: "person.crop.circle"
        }
    }
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .home
    @State private var showingAdd = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .home: OverviewView()
                case .insights: InsightsView()
                case .inbox: EmailScanView()
                case .profile: ProfileView()
                }
            }
            .id(selectedTab)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.985))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 78)

            CustomTabBar(selectedTab: $selectedTab, showingAdd: $showingAdd)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.standard, value: selectedTab)
        .background(RenewaTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionView()
                .presentationDetents([.large])
                .presentationCornerRadius(30)
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selectedTab: AppTab
    @Binding var showingAdd: Bool
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            item(.home)
            item(.insights)

            Button {
                withAnimation(RenewaMotion.quick) {
                    showingAdd = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(RenewaTheme.sage, in: Circle())
                    .shadow(color: RenewaTheme.sage.opacity(0.28), radius: 16, y: 6)
                    .rotationEffect(.degrees(showingAdd ? 45 : 0))
            }
            .buttonStyle(PressScaleStyle())
            .offset(y: -17)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Add subscription")

            item(.inbox)
            item(.profile)
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(RenewaTheme.divider.opacity(0.7)).frame(height: 1)
        }
    }

    private func item(_ tab: AppTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 21, weight: selectedTab == tab ? .semibold : .regular))
                    .frame(height: 25)
                Text(tab.title)
                    .font(.renewa(11, weight: selectedTab == tab ? .semibold : .medium))
            }
            .foregroundStyle(selectedTab == tab ? RenewaTheme.ink : RenewaTheme.muted.opacity(0.58))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                if selectedTab == tab {
                    Capsule()
                        .fill(RenewaTheme.ink)
                        .frame(width: 25, height: 3)
                        .offset(y: -10)
                        .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
        }
        .buttonStyle(PressScaleStyle())
    }
}
