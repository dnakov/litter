import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    @AppStorage("collapseTurns") private var collapseTurns = false

    private var currentServer: AppServerSnapshot? {
        if let activeServerId = appModel.snapshot?.activeThread?.serverId,
           let activeServer = appModel.snapshot?.servers.first(where: { $0.serverId == activeServerId }) {
            return activeServer
        }
        return appModel.snapshot?.servers.first
    }

    private var connectedServers: [HomeDashboardServer] {
        HomeDashboardSupport.sortedConnectedServers(
            from: appModel.snapshot?.servers ?? [],
            activeServerId: appModel.snapshot?.activeThread?.serverId
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    appearanceSection
                    fontSection
                    conversationSection
                    experimentalSection
                    accountSection
                    serversSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paintbrush")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    Text("Appearance")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Theme")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Conversation Section

    private var conversationSection: some View {
        Section {
            Toggle(isOn: $collapseTurns) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Collapse Turns")
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textPrimary)
                        Text("Collapse previous turns into cards")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
            }
            .tint(LitterTheme.accent)
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Conversation")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Font Section

    private var fontSection: some View {
        Section {
            ForEach(FontFamilyOption.allCases) { option in
                Button {
                    fontFamily = option.rawValue
                    ThemeManager.shared.syncFontPreference()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.displayName)
                                .litterFont(.subheadline)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text("The quick brown fox")
                                .font(LitterFont.sampleFont(family: option, size: 14))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if fontFamily == option.rawValue {
                            Image(systemName: "checkmark")
                                .litterFont(.subheadline, weight: .semibold)
                                .foregroundColor(LitterTheme.accentStrong)
                        }
                    }
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Font")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Experimental Section

    private var experimentalSection: some View {
        Section {
            NavigationLink {
                ExperimentalFeaturesView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "flask")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    Text("Experimental Features")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Experimental")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Account Section (inline, no nested sheet)

    private var accountSection: some View {
        Group {
            if let currentServer {
                SettingsConnectionAccountSection(server: currentServer)
            } else {
                SettingsDisconnectedAccountSection()
            }
        }
    }

    // MARK: - Servers Section

    private var serversSection: some View {
        Section {
            if connectedServers.isEmpty {
                Text("No servers connected")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textMuted)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            } else {
                ForEach(connectedServers, id: \.id) { conn in
                    HStack {
                        Image(systemName: conn.isLocal ? "iphone" : "server.rack")
                            .foregroundColor(LitterTheme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conn.displayName)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text(conn.health.displayLabel)
                                .litterFont(.caption)
                                .foregroundColor(conn.health.accentColor)
                        }
                        Spacer()
                        Button("Remove") {
                            SavedServerStore.remove(serverId: conn.id)
                            Task { await SshSessionStore.shared.close(serverId: conn.id, ssh: appModel.ssh) }
                            appModel.serverBridge.disconnectServer(serverId: conn.id)
                        }
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.danger)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            }
        } header: {
            Text("Servers")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

}

private struct SettingsConnectionAccountSection: View {
    @Environment(AppModel.self) private var appModel
    let server: AppServerSnapshot
    @State private var apiKey = ""
    @State private var isAuthWorking = false
    @State private var authError: String?

    var body: some View {
        Section {
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
                if server.account != nil {
                    Button("Logout") {
                        Task { await logout() }
                    }
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.danger)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))

            if server.account == nil {
                Button {
                    Task {
                        isAuthWorking = true
                        await loginWithChatGPT()
                        isAuthWorking = false
                    }
                } label: {
                    HStack {
                        if isAuthWorking {
                            ProgressView().tint(LitterTheme.textPrimary).scaleEffect(0.8)
                        }
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Login with ChatGPT")
                            .litterFont(.subheadline)
                    }
                    .foregroundColor(LitterTheme.accent)
                }
                .disabled(isAuthWorking)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if connection.target == .local, authStatus == .notLoggedIn || authStatus.isChatGPT {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        if authStatus.isChatGPT {
                            Text(connection.hasOpenAIApiKey ? "Update API key for local realtime" : "Save API key for local realtime")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        SecureField("sk-...", text: $apiKey)
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                    }
                    Button("Save") {
                        let key = apiKey.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        Task {
                            isAuthWorking = true
                            await saveApiKey(key)
                            isAuthWorking = false
                        }
                    }
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.accent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isAuthWorking)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if let authError {
                Text(authError)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.danger)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Account")
                .foregroundColor(LitterTheme.textSecondary)
        }
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

    private func loginWithChatGPT() async {
        do {
            authError = nil
            let tokens = try await ChatGPTOAuth.login()
            _ = try await appModel.rpc.loginAccount(
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
        do {
            authError = nil
            _ = try await appModel.rpc.loginAccount(
                serverId: server.serverId,
                params: .apiKey(apiKey: key)
            )
            await appModel.refreshSnapshot()
        } catch {
            authError = error.localizedDescription
        }
    }

    private func logout() async {
        do {
            try? ChatGPTOAuthTokenStore.shared.clear()
            _ = try await appModel.rpc.logoutAccount(serverId: server.serverId)
            await appModel.refreshSnapshot()
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }
}

private extension AuthStatus {
    var isChatGPT: Bool {
        if case .chatgpt = self {
            return true
        }
        return false
    }
}

private struct SettingsDisconnectedAccountSection: View {
    var body: some View {
        Section {
            Text("Connect to a server first")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Account")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }
}

#if DEBUG
#Preview("Settings") {
    LitterPreviewScene(includeBackground: false) {
        SettingsView()
    }
}
#endif
