import SwiftUI

struct AuthView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var createAccount = false
    @State private var appeared = false
    @State private var backgroundDrift = false
    @State private var socialNotice: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case displayName
        case email
        case password
        case confirmPassword
    }

    var body: some View {
        ZStack {
            RenewaTheme.background.ignoresSafeArea()
            Circle()
                .fill(RenewaTheme.sage.opacity(0.12))
                .frame(width: 320)
                .blur(radius: 2)
                .offset(
                    x: backgroundDrift && !reduceMotion ? 145 : 170,
                    y: backgroundDrift && !reduceMotion ? -305 : -330
                )

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer(minLength: 58)

                    ZStack {
                        Circle()
                            .fill(RenewaTheme.sage)
                            .frame(width: 62, height: 62)
                        HeroIcon(.arrowPath, size: 34)
                            .foregroundStyle(.white)
                    }
                    .rotationEffect(.degrees(createAccount && !reduceMotion ? 180 : 0))
                    .renewaEntrance(appeared, delay: 0.02)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(createAccount ? "Create your space." : "Welcome back.")
                            .font(.renewa(36, weight: .bold))
                            .foregroundStyle(RenewaTheme.ink)
                            .contentTransition(.opacity)
                        Text(
                            createAccount
                                ? "Start with a few details. We’ll personalize the rest next."
                                : "Your subscriptions, renewals, and inbox discoveries in one calm place."
                        )
                        .font(.renewa(17))
                        .foregroundStyle(RenewaTheme.muted)
                        .contentTransition(.opacity)
                    }
                    .renewaEntrance(appeared, delay: 0.08)

                    VStack(spacing: 13) {
                        if createAccount {
                            field(
                                "Full name",
                                text: $displayName,
                                icon: .user,
                                field: .displayName
                            )
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .focused($focusedField, equals: .displayName)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        field("Email", text: $email, icon: .envelope, field: .email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)

                        field(
                            "Password",
                            text: $password,
                            icon: .lockClosed,
                            field: .password,
                            secure: true
                        )
                        .textContentType(createAccount ? .newPassword : .password)
                        .focused($focusedField, equals: .password)

                        if createAccount {
                            field(
                                "Confirm password",
                                text: $confirmPassword,
                                icon: .checkCircle,
                                field: .confirmPassword,
                                secure: true
                            )
                            .textContentType(.newPassword)
                            .focused($focusedField, equals: .confirmPassword)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.renewa(13, weight: .medium))
                                .foregroundStyle(RenewaTheme.coral)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : RenewaMotion.standard, value: createAccount)
                    .renewaEntrance(appeared, delay: 0.14)

                    Button {
                        focusedField = nil
                        Task {
                            _ = await store.authenticate(
                                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: password,
                                displayName: createAccount ? displayName : nil,
                                createAccount: createAccount
                            )
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if store.isBusy {
                                ProgressView().tint(.white)
                            }
                            Text(createAccount ? "Create account" : "Sign in")
                                .font(.renewa(17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .foregroundStyle(.white)
                        .background(RenewaTheme.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(!isFormValid || store.isBusy)
                    .opacity(isFormValid ? 1 : 0.48)
                    .renewaEntrance(appeared, delay: 0.2)

                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(RenewaTheme.divider)
                            .frame(height: 1)
                        Text("or")
                            .font(.renewa(13, weight: .medium))
                            .foregroundStyle(RenewaTheme.muted)
                        Rectangle()
                            .fill(RenewaTheme.divider)
                            .frame(height: 1)
                    }

                    VStack(spacing: 11) {
                        socialButton(title: "Continue with Apple", mark: "") {
                            socialNotice = "Sign in with Apple is ready visually. It can be activated after the Apple Developer entitlement is added."
                        }
                        socialButton(title: "Continue with Google", mark: "G", isGoogle: true) {
                            socialNotice = "Google sign-in is ready visually. Add the Google OAuth credentials in Supabase to activate it."
                        }
                    }
                    .renewaEntrance(appeared, delay: 0.24)

                    Button {
                        withAnimation(reduceMotion ? nil : RenewaMotion.standard) {
                            createAccount.toggle()
                            confirmPassword = ""
                            focusedField = nil
                        }
                    } label: {
                        Text(createAccount ? "Already have an account? Sign in" : "New to Renewa? Create an account")
                            .font(.renewa(15, weight: .semibold))
                            .foregroundStyle(RenewaTheme.sage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressScaleStyle())
                    .renewaEntrance(appeared, delay: 0.28)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .alert(
            "Social sign-in",
            isPresented: Binding(
                get: { socialNotice != nil },
                set: { if !$0 { socialNotice = nil } }
            )
        ) {
            Button("Got it", role: .cancel) { socialNotice = nil }
        } message: {
            Text(socialNotice ?? "")
        }
        .onAppear {
            applyQALaunchState()
            appeared = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                backgroundDrift = true
            }
        }
    }

    private func applyQALaunchState() {
#if DEBUG
        if ProcessInfo.processInfo.environment["RENEWA_QA_SCREEN"] == "registration" {
            createAccount = true
        }
#endif
    }

    private var isFormValid: Bool {
        let validEmail = email.contains("@") && email.contains(".")
        guard validEmail, password.count >= 6 else { return false }
        if createAccount {
            return displayName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
                && confirmPassword == password
        }
        return true
    }

    private var validationMessage: String? {
        guard createAccount else { return nil }
        if !confirmPassword.isEmpty, confirmPassword != password {
            return "Passwords do not match."
        }
        if !password.isEmpty, password.count < 6 {
            return "Use at least 6 characters."
        }
        return nil
    }

    @ViewBuilder
    private func field(
        _ title: String,
        text: Binding<String>,
        icon: HeroIconName,
        field: Field,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            HeroIcon(icon, size: 21)
                .foregroundStyle(focusedField == field ? RenewaTheme.sage : RenewaTheme.muted)
                .frame(width: 24)
            if secure {
                SecureField(title, text: text)
            } else {
                TextField(title, text: text)
            }
        }
        .font(.renewa(16))
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(focusedField == field ? RenewaTheme.sage.opacity(0.7) : .clear, lineWidth: 1.5)
        }
        .animation(reduceMotion ? nil : RenewaMotion.quick, value: focusedField)
    }

    private func socialButton(
        title: String,
        mark: String,
        isGoogle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(mark)
                    .font(.system(size: isGoogle ? 19 : 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(isGoogle ? Color(red: 0.26, green: 0.52, blue: 0.96) : RenewaTheme.ink)
                    .frame(width: 25)
                Text(title)
                    .font(.renewa(15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(RenewaTheme.ink)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(RenewaTheme.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(RenewaTheme.divider.opacity(0.8), lineWidth: 1)
            }
        }
        .buttonStyle(PressScaleStyle())
    }
}
