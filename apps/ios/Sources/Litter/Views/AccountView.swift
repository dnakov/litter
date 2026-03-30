import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private var server: AppServerSnapshot? {
        if let activeServerId = appModel.snapshot?.activeThread?.serverId,
           let activeServer = appModel.snapshot?.servers.first(where: { $0.serverId == activeServerId }) {
            return activeServer
        }
        if let localServer = appModel.snapshot?.servers.first(where: \.isLocal) {
            return localServer
        }
        return appModel.snapshot?.servers.first
    }

    var body: some View {
        if let server {
            AccountConnectionView(server: server, dismiss: dismiss)
        } else {
            AccountDisconnectedView(dismiss: dismiss)
        }
    }
}

private struct AccountConnectionView: View {
    @Environment(AppModel.self) private var appModel
    let server: AppServerSnapshot
    let dismiss: DismissAction

    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var authError: String?
    @State private var hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        currentAccountSection
                        Divider().background(LitterTheme.surfaceLight)
                        loginSection
                        if let err = authError {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .task(id: server.serverId) {
                await refreshAccount()
                hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
            }
        }
    }

    private var currentAccountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT ACCOUNT")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Circle()
                    .fill(authColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authTitle)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    if let sub = authSubtitle {
                        Text(sub)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                Spacer()
                if server.isLocal, server.account != nil {
                    Button("Logout") {
                        Task { await logout() }
                    }
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.danger)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .padding(.horizontal, 16)

            if server.isLocal, hasStoredApiKey {
                Text("Local OpenAI API key is saved.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.accent)
                    .padding(.horizontal, 20)
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LOGIN")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .padding(.horizontal, 20)

            if server.isLocal, !isChatGPTAccount {
                Button {
                    Task {
                        isWorking = true
                        await loginWithChatGPT()
                        isWorking = false
                    }
                } label: {
                    HStack {
                        if isWorking {
                            ProgressView().tint(LitterTheme.textOnAccent).scaleEffect(0.8)
                        }
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Login with ChatGPT")
                            .litterFont(.subheadline)
                    }
                    .foregroundColor(LitterTheme.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(LitterTheme.accent)
                    .cornerRadius(10)
                }
                .padding(.horizontal, 16)
                .disabled(isWorking)
            } else {
                Text("Remote servers request their own OAuth login when needed. Local ChatGPT login and API key entry are not used here.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
                    .padding(.horizontal, 20)
            }

            if server.isLocal, allowsLocalEnvApiKey {
                Text("— or save an API key for the local environment —")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    if hasStoredApiKey {
                        Text("OpenAI API key saved in the local environment.")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                            .padding(.horizontal, 16)
                    } else if isChatGPTAccount {
                        Text("Save an OpenAI API key in the local Codex environment.")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                            .padding(.horizontal, 16)
                    }

                    SecureField("sk-...", text: $apiKey)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(LitterTheme.surface)
                        .cornerRadius(8)
                        .padding(.horizontal, 16)

                    Button {
                        let key = apiKey.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        Task {
                            isWorking = true
                            await saveApiKey(key)
                            isWorking = false
                        }
                    } label: {
                        Text(hasStoredApiKey ? "Update API Key" : "Save API Key")
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .background(LitterTheme.surface)
                            .cornerRadius(8)
                            .padding(.horizontal, 16)
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
        }
    }

    private var allowsLocalEnvApiKey: Bool {
        server.isLocal
    }

    private var isChatGPTAccount: Bool {
        if case .chatgpt? = server.account {
            return true
        }
        return false
    }
    private var authColor: Color {
        switch server.account {
        case .chatgpt?:
            return LitterTheme.accent
        case .apiKey?:
            return Color(hex: "#00AAFF")
        case nil:
            return LitterTheme.textMuted
        }
    }

    private var authTitle: String {
        switch server.account {
        case .chatgpt(let email, _)?:
            return email.isEmpty ? "ChatGPT" : email
        case .apiKey?:
            return "API Key"
        case nil:
            return "Not logged in"
        }
    }

    private var authSubtitle: String? {
        switch server.account {
        case .chatgpt?:
            return "ChatGPT account"
        case .apiKey?:
            return "OpenAI API key"
        case nil:
            return nil
        }
    }

    private func refreshAccount() async {
        do {
            _ = try await appModel.client.refreshAccount(
                serverId: server.serverId,
                params: AppRefreshAccountRequest(refreshToken: false)
            )
            await appModel.refreshSnapshot()
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    private func loginWithChatGPT() async {
        guard server.isLocal else {
            authError = "Account login is only available for the local server."
            return
        }
        do {
            authError = nil
            let tokens = try await ChatGPTOAuth.login()
            _ = try await appModel.client.loginAccount(
                serverId: server.serverId,
                params: .chatgptAuthTokens(
                    accessToken: tokens.accessToken,
                    chatgptAccountId: tokens.accountID,
                    chatgptPlanType: tokens.planType
                )
            )
            await appModel.refreshSnapshot()
        } catch ChatGPTOAuthError.cancelled {
            return
        } catch {
            authError = error.localizedDescription
        }
    }

    private func saveApiKey(_ key: String) async {
        guard server.isLocal else {
            authError = "API keys can only be saved for the local server."
            return
        }
        do {
            authError = nil
            try OpenAIApiKeyStore.shared.save(key)
            if case .apiKey? = server.account {
                _ = try await appModel.client.logoutAccount(serverId: server.serverId)
            }
            try await appModel.restartLocalServer()
            hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
            guard hasStoredApiKey else {
                authError = "API key did not persist locally."
                return
            }
            dismiss()
        } catch {
            authError = error.localizedDescription
        }
    }

    private func logout() async {
        guard server.isLocal else {
            authError = "Account logout is only available for the local server."
            return
        }
        do {
            try? ChatGPTOAuthTokenStore.shared.clear()
            try? OpenAIApiKeyStore.shared.clear()
            _ = try await appModel.client.logoutAccount(serverId: server.serverId)
            try await appModel.restartLocalServer()
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }
}

private struct AccountDisconnectedView: View {
    let dismiss: DismissAction

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Connect to a server first")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text("Account settings are tied to the active server connection.")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Account") {
    LitterPreviewScene(includeBackground: false) {
        AccountView()
    }
}
#endif
