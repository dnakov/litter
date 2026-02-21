import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAccount = false

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
                                        .font(.system(.subheadline, design: .monospaced))
                                    Text(accountSummary)
                                        .font(.system(.caption, design: .monospaced))
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
                        let connected = serverManager.connections.values.filter { $0.isConnected }
                        if connected.isEmpty {
                            Text("No servers connected")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(LitterTheme.textMuted)
                                .listRowBackground(LitterTheme.surface.opacity(0.6))
                        } else {
                            ForEach(Array(connected), id: \.id) { conn in
                                HStack {
                                    Image(systemName: serverIconName(for: conn.server.source))
                                        .foregroundColor(LitterTheme.accent)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conn.server.name)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundColor(.white)
                                        Text(conn.isConnected ? "Connected" : "Disconnected")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(conn.isConnected ? LitterTheme.accent : LitterTheme.textSecondary)
                                    }
                                    Spacer()
                                    Button("Remove") {
                                        serverManager.removeServer(id: conn.id)
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(Color(hex: "#FF5555"))
                                }
                                .listRowBackground(LitterTheme.surface.opacity(0.6))
                            }
                        }
                    } header: {
                        Text("Servers")
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
