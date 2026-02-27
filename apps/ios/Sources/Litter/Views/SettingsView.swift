import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAccount = false

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
                    Section {
                        Button {
                            showAccount = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Account")
                                        .foregroundColor(.white)
                                        .font(LitterFont.monospaced(.subheadline))
                                    Text(accountSummary)
                                        .font(LitterFont.monospaced(.caption))
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(LitterTheme.textMuted)
                                    .font(.caption)
                            }
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    } header: {
                        Text("Authentication")
                            .foregroundColor(LitterTheme.textSecondary)
                    }

                    Section {
                        if connectedServers.isEmpty {
                            Text("No servers connected")
                                .font(LitterFont.monospaced(.footnote))
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
                                            .font(LitterFont.monospaced(.footnote))
                                            .foregroundColor(.white)
                                        Text(conn.isConnected ? "Connected" : "Disconnected")
                                            .font(LitterFont.monospaced(.caption))
                                            .foregroundColor(conn.isConnected ? LitterTheme.accent : LitterTheme.textSecondary)
                                    }
                                    Spacer()
                                    Button("Remove") {
                                        serverManager.removeServer(id: conn.id)
                                    }
                                    .font(LitterFont.monospaced(.caption))
                                    .foregroundColor(Color(hex: "#FF5555"))
                                }
                                .listRowBackground(LitterTheme.surface.opacity(0.6))
                            }
                        }
                    } header: {
                        Text("Servers")
                            .foregroundColor(LitterTheme.textSecondary)
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Font")
                                .font(LitterFont.monospaced(.subheadline))
                                .foregroundColor(.white)
                            Text("Berkeley Mono is not bundled. Please upload your own licensed .otf or .ttf monospace font.")
                                .font(LitterFont.monospaced(.caption))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    } header: {
                        Text("Typography")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
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
        .sheet(isPresented: $showAccount) {
            AccountView()
                .environmentObject(serverManager)
        }
    }

    private var accountSummary: String {
        let conn = serverManager.activeConnection ?? serverManager.connections.values.first(where: { $0.isConnected })
        guard let conn else { return "Connect first" }
        switch conn.authStatus {
        case .chatgpt(let email): return email.isEmpty ? "ChatGPT" : email
        case .apiKey: return "API Key"
        case .notLoggedIn: return "Not logged in"
        case .unknown: return conn.isConnected ? "Checking…" : "Connect first"
        }
    }
}
