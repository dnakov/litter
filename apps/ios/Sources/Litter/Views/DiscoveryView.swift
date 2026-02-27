import SwiftUI

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @StateObject private var discovery = NetworkDiscovery()
    @State private var sshServer: DiscoveredServer?
    @State private var showManualEntry = false
    @State private var manualHost = ""
    @State private var manualPort = "8390"
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var connectError: String?

    private var localServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source == .local }
    }

    private var networkServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source != .local }
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            List {
                Section {
                    HStack {
                        Spacer()
                        BrandLogo(size: 86)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if !localServers.isEmpty {
                    localSection
                }
                networkSection
                manualSection
            }
            .scrollContentBackground(.hidden)
            .refreshable { discovery.startScanning() }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    discovery.startScanning()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(LitterTheme.accent)
                }
                .disabled(discovery.isScanning)
            }
        }
        .onAppear {
            discovery.startScanning()
            maybeStartSimulatorAutoSSH()
        }
        .onDisappear { discovery.stopScanning() }
        .sheet(item: $sshServer) { server in
            SSHLoginSheet(server: server) { target in
                sshServer = nil
                switch target {
                case .remote(let host, let port):
                    let resolved = DiscoveredServer(
                        id: "\(server.id)-remote-\(port)",
                        name: server.name,
                        hostname: host,
                        port: port,
                        source: server.source,
                        hasCodexServer: true
                    )
                    Task { await connectToServer(resolved) }
                default:
                    Task { await connectToServer(server) }
                }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
        .alert("Connection Failed", isPresented: showConnectError, actions: {
            Button("OK") { connectError = nil }
        }, message: {
            Text(connectError ?? "Unable to connect.")
        })
    }

    // MARK: - Sections

    private var localSection: some View {
        Section {
            ForEach(localServers) { server in
                serverRow(server)
            }
        } header: {
            Text("This Device")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var networkSection: some View {
        Section {
            if networkServers.isEmpty {
                if discovery.isScanning {
                    HStack {
                        ProgressView().tint(LitterTheme.textMuted).scaleEffect(0.7)
                        Text("Scanning Bonjour + Tailscale...")
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                } else {
                    Text("No IPv4 Codex/SSH hosts found via Bonjour/Tailscale")
                        .font(LitterFont.monospaced(.footnote))
                        .foregroundColor(LitterTheme.textMuted)
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            } else {
                ForEach(networkServers) { server in
                    serverRow(server)
                }
            }
        } header: {
            Text("Network")
                .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var manualSection: some View {
        Section {
            Button {
                showManualEntry = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(LitterTheme.accent)
                    Text("Add Server")
                        .font(LitterFont.monospaced(.subheadline))
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
    }

    // MARK: - Row

    private func serverRow(_ server: DiscoveredServer) -> some View {
        Button {
            handleTap(server)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: serverIconName(for: server.source))
                    .foregroundColor(server.hasCodexServer ? LitterTheme.accent : LitterTheme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(LitterFont.monospaced(.subheadline))
                        .foregroundColor(.white)
                    Text(serverSubtitle(server))
                        .font(LitterFont.monospaced(.caption))
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Spacer()
                if serverManager.connections[server.id]?.isConnected == true {
                    Text("connected")
                        .font(LitterFont.monospaced(.caption2))
                        .foregroundColor(LitterTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LitterTheme.accent.opacity(0.15))
                        .cornerRadius(4)
                } else if connectingServer?.id == server.id {
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(LitterTheme.textMuted)
                        .font(.caption)
                }
            }
        }
        .disabled(connectingServer != nil)
    }

    private func serverSubtitle(_ server: DiscoveredServer) -> String {
        if server.source == .local { return "In-process server" }
        var parts = [server.hostname]
        if let port = server.port { parts.append(":\(port)") }
        if server.hasCodexServer {
            parts.append(" - codex running")
        } else {
            parts.append(" - SSH (\(server.source.rawString))")
        }
        return parts.joined()
    }

    // MARK: - Actions

    private func handleTap(_ server: DiscoveredServer) {
        if serverManager.connections[server.id]?.isConnected == true {
            onServerSelected?(server)
            return
        }
        if server.hasCodexServer {
            Task { await connectToServer(server) }
        } else {
            sshServer = server
        }
    }

    private func connectToServer(_ server: DiscoveredServer) async {
        guard connectingServer == nil else { return }
        connectingServer = server
        connectError = nil

        guard let target = server.connectionTarget else {
            connectError = "Server requires SSH login"
            connectingServer = nil
            return
        }

        await serverManager.addServer(server, target: target)

        let connected = serverManager.connections[server.id]?.isConnected == true
        connectingServer = nil
        if connected {
            onServerSelected?(server)
        } else {
            let phase = serverManager.connections[server.id]?.connectionPhase
            connectError = phase?.isEmpty == false ? phase : "Failed to connect"
        }
    }

    // MARK: - Manual Entry

    private var manualEntrySheet: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    Section {
                        TextField("hostname or IP", text: $manualHost)
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(.white)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        TextField("port", text: $manualPort)
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(.white)
                            .keyboardType(.numberPad)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Button("Connect") {
                            guard !manualHost.isEmpty, let port = UInt16(manualPort) else { return }
                            let server = DiscoveredServer(
                                id: "manual-\(manualHost):\(port)",
                                name: manualHost, hostname: manualHost,
                                port: port, source: .manual, hasCodexServer: true
                            )
                            showManualEntry = false
                            Task { await connectToServer(server) }
                        }
                        .foregroundColor(LitterTheme.accent)
                        .font(LitterFont.monospaced(.subheadline))
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showManualEntry = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func maybeStartSimulatorAutoSSH() {
#if DEBUG
        guard !autoSSHStarted else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXIOS_SIM_AUTO_SSH"] == "1",
              let host = env["CODEXIOS_SIM_AUTO_SSH_HOST"], !host.isEmpty,
              let user = env["CODEXIOS_SIM_AUTO_SSH_USER"], !user.isEmpty,
              let pass = env["CODEXIOS_SIM_AUTO_SSH_PASS"], !pass.isEmpty else {
            return
        }
        autoSSHStarted = true

        Task {
            do {
                NSLog("[AUTO_SSH] connecting to %@ as %@", host, user)
                let ssh = SSHSessionManager.shared
                try await ssh.connect(host: host, credentials: .password(username: user, password: pass))
                let port = try await ssh.startRemoteServer()
                NSLog("[AUTO_SSH] remote app-server port %d", Int(port))
                let server = DiscoveredServer(
                    id: "auto-ssh-\(host):\(port)",
                    name: host,
                    hostname: host,
                    port: port,
                    source: .manual,
                    hasCodexServer: true
                )
                await connectToServer(server)
            } catch {
                NSLog("[AUTO_SSH] failed: %@", error.localizedDescription)
            }
        }
#endif
    }

    private var showConnectError: Binding<Bool> {
        Binding(
            get: { connectError != nil },
            set: { newValue in
                if !newValue {
                    connectError = nil
                }
            }
        )
    }
}
