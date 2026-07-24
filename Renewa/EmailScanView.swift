import AuthenticationServices
import SwiftUI

struct EmailScanView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScanning = false
    @State private var scanResult: EmailScanResult?
    @State private var webSession: ASWebAuthenticationSession?
    @State private var statusText = "Connect an inbox to discover new, renewed, and canceled subscriptions."
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inbox intelligence")
                        .font(.renewa(31, weight: .bold))
                    Text("Private by design. Analysis happens on the backend and mail access stays read-only.")
                        .font(.renewa(15))
                        .foregroundStyle(RenewaTheme.muted)
                }
                .padding(.top, 18)
                .renewaEntrance(appeared, delay: 0.02)

                ZStack {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [RenewaTheme.sage.opacity(0.96), Color(red: 0.24, green: 0.43, blue: 0.37)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 18) {
                        ZStack {
                            ForEach(0..<3) { index in
                                Circle()
                                    .stroke(.white.opacity(0.16 - Double(index) * 0.035), lineWidth: 1)
                                    .frame(width: CGFloat(86 + index * 35))
                                    .scaleEffect(isScanning ? 1.12 : 0.92)
                                    .animation(
                                        reduceMotion
                                            ? nil
                                            : .easeInOut(duration: 1.1 + Double(index) * 0.18)
                                                .repeatForever(autoreverses: true),
                                        value: isScanning
                                    )
                            }
                            HeroIcon(
                                isScanning ? .sparkles : .envelope,
                                style: .solid,
                                size: 40
                            )
                                .foregroundStyle(.white)
                                .scaleEffect(isScanning && !reduceMotion ? 1.08 : 1)
                        }
                        .frame(height: 150)

                        Text(isScanning ? "Reading billing signals…" : "Find what you’re paying for")
                            .font(.renewa(22, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.opacity)
                        Text(statusText)
                            .font(.renewa(14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .contentTransition(.opacity)
                    }
                    .padding(24)
                }
                .frame(height: 330)
                .scaleEffect(isScanning && !reduceMotion ? 1.012 : 1)
                .shadow(
                    color: RenewaTheme.sage.opacity(isScanning ? 0.24 : 0.08),
                    radius: isScanning ? 24 : 10,
                    y: isScanning ? 12 : 5
                )
                .animation(reduceMotion ? nil : RenewaMotion.standard, value: isScanning)
                .renewaEntrance(appeared, delay: 0.08)

                if let scanResult {
                    RenewaCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Scan complete")
                                .font(.renewa(19, weight: .bold))
                            HStack {
                                resultMetric("\(scanResult.scanned)", label: "Emails")
                                resultMetric("\(scanResult.added)", label: "Added")
                                resultMetric("\(scanResult.canceled)", label: "Canceled")
                            }
                        }
                    }
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                }

                VStack(spacing: 12) {
                    actionButton("Scan connected inbox") {
                        await runScan()
                    }
                    HStack(spacing: 12) {
                        providerButton("Google", mark: "G", provider: "google")
                        providerButton("Microsoft", mark: "M", provider: "microsoft")
                    }
                }
                .renewaEntrance(appeared, delay: 0.16)

                Label {
                    Text("Renewa requests read-only email access and only sends likely billing messages for extraction.")
                } icon: {
                    HeroIcon(.lockClosed, size: 20)
                }
                .font(.renewa(13, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
                .renewaEntrance(appeared, delay: 0.22)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(RenewaTheme.background)
        .onAppear {
            appeared = true
        }
    }

    private func resultMetric(_ value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.renewa(25, weight: .bold))
            Text(label)
                .font(.renewa(12, weight: .medium))
                .foregroundStyle(RenewaTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func actionButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                if isScanning {
                    ProgressView().tint(.white)
                } else {
                    HeroIcon(.sparkles, style: .solid, size: 20)
                }
                Text(title)
                    .font(.renewa(16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(isScanning)
    }

    private func providerButton(_ title: String, mark: String, provider: String) -> some View {
        Button {
            Task { await connect(provider) }
        } label: {
            HStack(spacing: 8) {
                Text(mark)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(provider == "google" ? Color(red: 0.26, green: 0.52, blue: 0.96) : RenewaTheme.sage)
                Text(title)
                    .font(.renewa(14, weight: .semibold))
            }
                .foregroundStyle(RenewaTheme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
    }

    private func runScan() async {
        withAnimation(reduceMotion ? nil : RenewaMotion.standard) {
            isScanning = true
            scanResult = nil
            statusText = "Looking for receipts, renewals, trials, and cancellations."
        }
        do {
            let result = try await store.scanEmail()
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : RenewaMotion.standard) {
                scanResult = result
                statusText = "Your subscription list is now up to date."
            }
        } catch {
            store.errorMessage = error.localizedDescription
            statusText = "The scan could not be completed."
        }
        withAnimation(reduceMotion ? nil : RenewaMotion.quick) {
            isScanning = false
        }
    }

    private func connect(_ provider: String) async {
        do {
            let url = try await store.emailAuthorizationURL(provider: provider)
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "renewa") { callbackURL, error in
                Task { @MainActor in
                    withAnimation(reduceMotion ? nil : RenewaMotion.standard) {
                        if let error {
                            statusText = "Connection wasn’t completed: \(error.localizedDescription)"
                        } else if callbackURL != nil {
                            statusText = "\(provider.capitalized) connected. You can scan now."
                        }
                    }
                    webSession = nil
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = OAuthPresentationContext.shared
            webSession = session
            session.start()
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
