import SwiftUI

struct AccountView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var errorMsg: String?
    @State private var showOAuth = false

    private var conn: ServerConnection? {
        serverManager.activeConnection ?? serverManager.connections.values.first(where: { $0.isConnected })
    }

    private var authStatus: AuthStatus {
        conn?.authStatus ?? .unknown
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        currentAccountSection
                        Divider().background(LitterTheme.surfaceLight)
                        loginSection
                        if let err = errorMsg {
                            Text(err).font(.caption).foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showOAuth) {
            oauthSheet
        }
        .onChange(of: conn?.oauthURL) { url in
            showOAuth = url != nil
        }
        .onChange(of: conn?.loginCompleted) { completed in
            if completed == true {
                showOAuth = false
                conn?.loginCompleted = false
            }
        }
    }

    private var currentAccountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT ACCOUNT")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.textMuted)
                .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Circle()
                    .fill(authColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authTitle)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.white)
                    if let sub = authSubtitle {
                        Text(sub)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                Spacer()
                if authStatus != .notLoggedIn && authStatus != .unknown {
                    Button("Logout") {
                        Task { await conn?.logout() }
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Color(hex: "#FF5555"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .padding(.horizontal, 16)
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LOGIN")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.textMuted)
                .padding(.horizontal, 20)

            Button {
                Task {
                    isWorking = true
                    errorMsg = nil
                    await conn?.loginWithChatGPT()
                    isWorking = false
                }
            } label: {
                HStack {
                    if isWorking {
                        ProgressView().tint(Color(hex: "#0D0D0D")).scaleEffect(0.8)
                    }
                    Image(systemName: "person.crop.circle.badge.checkmark")
                    Text("Login with ChatGPT")
                        .font(.system(.subheadline, design: .monospaced))
                }
                .foregroundColor(Color(hex: "#0D0D0D"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(LitterTheme.accent)
                .cornerRadius(10)
            }
            .padding(.horizontal, 16)
            .disabled(isWorking)

            Text("— or use an API key —")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.textMuted)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                SecureField("sk-...", text: $apiKey)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(LitterTheme.surface)
                    .cornerRadius(8)
                    .padding(.horizontal, 16)

                Button {
                    let key = apiKey.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    Task {
                        isWorking = true
                        errorMsg = nil
                        await conn?.loginWithApiKey(key)
                        isWorking = false
                        if case .apiKey = authStatus { dismiss() }
                    }
                } label: {
                    Text("Save API Key")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(LitterTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(LitterTheme.accent.opacity(0.4), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 16)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
    }

    @ViewBuilder
    private var oauthSheet: some View {
        if let url = conn?.oauthURL {
            NavigationStack {
                SafariView(url: url) {
                    Task { await conn?.cancelLogin() }
                }
                .ignoresSafeArea()
                .navigationTitle("Login with ChatGPT")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            Task { await conn?.cancelLogin() }
                            showOAuth = false
                        }
                        .foregroundColor(Color(hex: "#FF5555"))
                    }
                }
            }
        }
    }

    private var authColor: Color {
        switch authStatus {
        case .chatgpt: return LitterTheme.accent
        case .apiKey:  return Color(hex: "#00AAFF")
        case .notLoggedIn, .unknown: return LitterTheme.textMuted
        }
    }

    private var authTitle: String {
        switch authStatus {
        case .chatgpt(let email): return email.isEmpty ? "ChatGPT" : email
        case .apiKey: return "API Key"
        case .notLoggedIn: return "Not logged in"
        case .unknown: return "Checking…"
        }
    }

    private var authSubtitle: String? {
        switch authStatus {
        case .chatgpt: return "ChatGPT account"
        case .apiKey: return "OpenAI API key"
        default: return nil
        }
    }
}
