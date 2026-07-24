import SwiftUI

struct AuthView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false
    @State private var appeared = false
    @State private var backgroundDrift = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
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
                VStack(alignment: .leading, spacing: 26) {
                    Spacer(minLength: 80)

                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(RenewaTheme.sage)
                        .rotationEffect(.degrees(createAccount && !reduceMotion ? 180 : 0))
                        .symbolEffect(.bounce, value: createAccount)
                        .renewaEntrance(appeared, delay: 0.02)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(createAccount ? "Start fresh." : "Welcome back.")
                            .font(.renewa(36, weight: .bold))
                            .foregroundStyle(RenewaTheme.ink)
                            .contentTransition(.opacity)
                        Text("Your subscriptions, renewals, and inbox discoveries in one calm place.")
                            .font(.renewa(17))
                            .foregroundStyle(RenewaTheme.muted)
                    }
                    .renewaEntrance(appeared, delay: 0.08)

                    VStack(spacing: 14) {
                        field("Email", text: $email, icon: "envelope", field: .email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .email)

                        field("Password", text: $password, icon: "lock", field: .password, secure: true)
                            .textContentType(createAccount ? .newPassword : .password)
                            .focused($focusedField, equals: .password)
                    }
                    .renewaEntrance(appeared, delay: 0.14)

                    Button {
                        focusedField = nil
                        Task {
                            _ = await store.authenticate(
                                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: password,
                                createAccount: createAccount
                            )
                        }
                    } label: {
                        HStack {
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
                    .disabled(email.isEmpty || password.count < 6 || store.isBusy)
                    .opacity(email.isEmpty || password.count < 6 ? 0.55 : 1)
                    .renewaEntrance(appeared, delay: 0.2)

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            createAccount.toggle()
                        }
                    } label: {
                        Text(createAccount ? "Already have an account? Sign in" : "New to Renewa? Create an account")
                            .font(.renewa(15, weight: .semibold))
                            .foregroundStyle(RenewaTheme.sage)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressScaleStyle())
                    .renewaEntrance(appeared, delay: 0.26)
                }
                .padding(.horizontal, 28)
            }
        }
        .onAppear {
            appeared = true
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                backgroundDrift = true
            }
        }
    }

    @ViewBuilder
    private func field(
        _ title: String,
        text: Binding<String>,
        icon: String,
        field: Field,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
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
}
