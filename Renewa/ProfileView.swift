import SwiftUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Circle()
                        .fill(RenewaTheme.divider)
                        .frame(width: 84, height: 84)
                        .overlay {
                            Text(initial)
                                .font(.renewa(30, weight: .bold))
                                .foregroundStyle(RenewaTheme.sage)
                        }
                    Text(store.displayName)
                        .font(.renewa(18, weight: .semibold))
                    Text(store.session?.user.email ?? "")
                        .font(.renewa(14))
                        .foregroundStyle(RenewaTheme.muted)
                    Label("Synced", systemImage: "checkmark.circle.fill")
                        .font(.renewa(12, weight: .bold))
                        .foregroundStyle(RenewaTheme.sage)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(RenewaTheme.sage.opacity(0.1), in: Capsule())
                        .symbolEffect(.bounce, value: appeared)
                }
                .padding(.top, 24)
                .renewaEntrance(appeared, delay: 0.02)

                RenewaCard {
                    VStack(spacing: 0) {
                        informationRow("Account storage", value: "Supabase", icon: "externaldrive.fill")
                        Divider().padding(.leading, 44)
                        informationRow("Default currency", value: store.defaultCurrency, icon: "dollarsign.circle.fill")
                        Divider().padding(.leading, 44)
                        informationRow(
                            "Subscriptions",
                            value: "\(store.activeSubscriptions.count) active",
                            icon: "arrow.trianglehead.2.clockwise.rotate.90"
                        )
                    }
                }
                .renewaEntrance(appeared, delay: 0.1)

                RenewaCard {
                    Label {
                        Text("Session data is stored in Keychain. Mail tokens and AI credentials stay on the backend.")
                            .font(.renewa(14))
                            .foregroundStyle(RenewaTheme.muted)
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(RenewaTheme.sage)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .renewaEntrance(appeared, delay: 0.17)

                Button(role: .destructive) {
                    Task { await store.signOut() }
                } label: {
                    Text("Sign out")
                        .font(.renewa(16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.bordered)
                .tint(RenewaTheme.coral)
                .renewaEntrance(appeared, delay: 0.24)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .background(RenewaTheme.background)
        .onAppear {
            appeared = true
        }
    }

    private var initial: String {
        String(store.displayName.prefix(1)).uppercased()
    }

    private func informationRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(RenewaTheme.sage)
                .frame(width: 30, height: 44)
            Text(title)
                .font(.renewa(15, weight: .medium))
            Spacer()
            Text(value)
                .font(.renewa(14))
                .foregroundStyle(RenewaTheme.muted)
        }
    }
}
