import SwiftUI

struct SettingsView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    @AppStorage("collapseTurns") private var collapseTurns = false

    private var connection: ServerConnection? {
        serverManager.activeConnection ?? serverManager.connections.values.first(where: { $0.isConnected })
    }

    private var connectedServers: [ServerConnection] {
        serverManager.connections.values
            .filter { $0.isConnected }
            .sorted { lhs, rhs in
                lhs.server.name.localizedCaseInsensitiveCompare(rhs.server.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    appearanceSection
                    conversationSection
                    fontSection
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
                        .font(LitterFont.styled(.subheadline))
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
                            .font(LitterFont.styled(.subheadline))
                            .foregroundColor(LitterTheme.textPrimary)
                        Text("Collapse previous turns into cards")
                            .font(LitterFont.styled(.caption))
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
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.displayName)
                                .font(LitterFont.styled(.subheadline))
                                .foregroundColor(LitterTheme.textPrimary)
                            Text("The quick brown fox")
                                .font(LitterFont.sampleFont(family: option, size: 14))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if fontFamily == option.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(.subheadline, weight: .semibold))
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
                        .font(LitterFont.styled(.subheadline))
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
            if let connection {
                SettingsConnectionAccountSection(connection: connection)
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
                    .font(LitterFont.styled(.footnote))
                    .foregroundColor(LitterTheme.textMuted)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            } else {
                ForEach(connectedServers, id: \.id) { conn in
                    HStack {
                        Image(systemName: serverIconName(for: conn.server.source))
                            .foregroundColor(LitterTheme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conn.server.name)
                                .font(LitterFont.styled(.footnote))
                                .foregroundColor(LitterTheme.textPrimary)
                            Text(conn.connectionHealth.settingsLabel)
                                .font(LitterFont.styled(.caption))
                                .foregroundColor(conn.connectionHealth.settingsColor)
                        }
                        Spacer()
                        Button("Remove") {
                            serverManager.removeServer(id: conn.id)
                        }
                        .font(LitterFont.styled(.caption))
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
    let connection: ServerConnection
    @State private var apiKey = ""
    @State private var isAuthWorking = false
    @State private var authError: String?
    @State private var showOAuth = false

    private var authStatus: AuthStatus {
        connection.authStatus
    }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(authColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authTitle)
                        .font(LitterFont.styled(.subheadline))
                        .foregroundColor(LitterTheme.textPrimary)
                    if let sub = authSubtitle {
                        Text(sub)
                            .font(LitterFont.styled(.caption))
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                Spacer()
                if authStatus != .notLoggedIn && authStatus != .unknown {
                    Button("Logout") {
                        Task { await connection.logout() }
                    }
                    .font(LitterFont.styled(.caption))
                    .foregroundColor(LitterTheme.danger)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))

            if case .notLoggedIn = authStatus {
                Button {
                    Task {
                        isAuthWorking = true
                        authError = nil
                        await connection.loginWithChatGPT()
                        isAuthWorking = false
                    }
                } label: {
                    HStack {
                        if isAuthWorking {
                            ProgressView().tint(LitterTheme.textPrimary).scaleEffect(0.8)
                        }
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Login with ChatGPT")
                            .font(LitterFont.styled(.subheadline))
                    }
                    .foregroundColor(LitterTheme.accent)
                }
                .disabled(isAuthWorking)
                .listRowBackground(LitterTheme.surface.opacity(0.6))

                HStack(spacing: 8) {
                    SecureField("sk-...", text: $apiKey)
                        .font(LitterFont.styled(.footnote))
                        .foregroundColor(LitterTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                    Button("Save") {
                        let key = apiKey.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        Task {
                            isAuthWorking = true
                            authError = nil
                            await connection.loginWithApiKey(key)
                            isAuthWorking = false
                        }
                    }
                    .font(LitterFont.styled(.caption))
                    .foregroundColor(LitterTheme.accent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isAuthWorking)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if let authError {
                Text(authError)
                    .font(LitterFont.styled(.caption))
                    .foregroundColor(LitterTheme.danger)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Account")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .sheet(isPresented: $showOAuth) {
            oauthSheet
        }
        .onChange(of: connection.oauthURL) { _, url in
            showOAuth = url != nil
        }
        .onChange(of: connection.loginCompleted) { _, completed in
            if completed == true {
                showOAuth = false
                connection.loginCompleted = false
            }
        }
    }

    @ViewBuilder
    private var oauthSheet: some View {
        if let url = connection.oauthURL {
            NavigationStack {
                OAuthWebView(url: url, onCallbackIntercepted: { callbackURL in
                    connection.forwardOAuthCallback(callbackURL)
                }) {
                    Task { await connection.cancelLogin() }
                }
                .ignoresSafeArea()
                .navigationTitle("Login with ChatGPT")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            Task { await connection.cancelLogin() }
                            showOAuth = false
                        }
                        .foregroundColor(LitterTheme.danger)
                    }
                }
            }
        }
    }

    private var authColor: Color {
        switch authStatus {
        case .chatgpt: return LitterTheme.accent
        case .apiKey: return Color(hex: "#00AAFF")
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

private struct SettingsDisconnectedAccountSection: View {
    var body: some View {
        Section {
            Text("Connect to a server first")
                .font(LitterFont.styled(.caption))
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
