import SwiftUI

struct SSHLoginSheet: View {
    let server: DiscoveredServer
    let onConnect: (ConnectionTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var useKey = false
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var rememberCredentials = true
    @State private var hasSavedCredentials = false
    @State private var loadedSavedCredentials = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .foregroundColor(LitterTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(LitterFont.monospaced(.subheadline))
                                    .foregroundColor(.white)
                                Text(server.hostname)
                                    .font(LitterFont.monospaced(.caption))
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        TextField("username", text: $username)
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(.white)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    } header: {
                        Text("Username")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Picker("Method", selection: $useKey) {
                            Text("Password").tag(false)
                            Text("SSH Key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(LitterTheme.surface.opacity(0.6))

                        if useKey {
                            TextEditor(text: $privateKey)
                                .font(LitterFont.monospaced(.caption))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 100)
                                .overlay(alignment: .topLeading) {
                                    if privateKey.isEmpty {
                                        Text("Paste private key here...")
                                            .font(LitterFont.monospaced(.caption))
                                            .foregroundColor(LitterTheme.textMuted)
                                            .padding(.top, 8)
                                            .padding(.leading, 4)
                                            .allowsHitTesting(false)
                                    }
                                }
                            SecureField("passphrase (optional)", text: $passphrase)
                                .font(LitterFont.monospaced(.footnote))
                                .foregroundColor(.white)
                        } else {
                            SecureField("password", text: $password)
                                .font(LitterFont.monospaced(.footnote))
                                .foregroundColor(.white)
                        }
                    } header: {
                        Text("Authentication")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Toggle(isOn: $rememberCredentials) {
                            Text("Remember credentials on this device")
                                .font(LitterFont.monospaced(.footnote))
                                .foregroundColor(.white)
                        }
                        .tint(LitterTheme.accent)

                        if hasSavedCredentials {
                            Button(role: .destructive) {
                                forgetSavedCredentials()
                            } label: {
                                Text("Forget saved credentials")
                                    .font(LitterFont.monospaced(.footnote))
                            }
                        }
                    } header: {
                        Text("Saved Credentials")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Button {
                            connect()
                        } label: {
                            HStack {
                                if isConnecting {
                                    ProgressView().tint(LitterTheme.accent)
                                }
                                Text("Connect")
                                    .foregroundColor(LitterTheme.accent)
                                    .font(LitterFont.monospaced(.subheadline))
                            }
                        }
                        .disabled(isConnecting || username.isEmpty || (!useKey && password.isEmpty) || (useKey && privateKey.isEmpty))
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    if let err = errorMessage {
                        Section {
                            Text(err)
                                .foregroundColor(.red)
                                .font(LitterFont.monospaced(.caption))
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("SSH Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            loadSavedCredentialsIfNeeded()
        }
    }

    private func connect() {
        let credentials: SSHCredentials
        if useKey {
            credentials = .key(
                username: username,
                privateKey: privateKey,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
        } else {
            credentials = .password(username: username, password: password)
        }
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let ssh = SSHSessionManager.shared
                try await ssh.connect(host: server.hostname, credentials: credentials)
                let port = try await ssh.startRemoteServer()
                var remoteHost = server.hostname
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .replacingOccurrences(of: "%25", with: "%")
                if !remoteHost.contains(":"), let pct = remoteHost.firstIndex(of: "%") {
                    remoteHost = String(remoteHost[..<pct])
                }
                let target = ConnectionTarget.remote(host: remoteHost, port: port)

                do {
                    if rememberCredentials {
                        try SSHCredentialStore.shared.save(savedCredential(from: credentials), host: server.hostname)
                        hasSavedCredentials = true
                    } else {
                        try SSHCredentialStore.shared.delete(host: server.hostname)
                        hasSavedCredentials = false
                    }
                } catch {
                    NSLog("[SSH_CREDENTIALS] keychain update failed: %@", error.localizedDescription)
                }

                clearSensitiveInput()
                isConnecting = false
                onConnect(target)
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadSavedCredentialsIfNeeded() {
        guard !loadedSavedCredentials else { return }
        loadedSavedCredentials = true

        do {
            guard let saved = try SSHCredentialStore.shared.load(host: server.hostname) else {
                hasSavedCredentials = false
                return
            }
            hasSavedCredentials = true
            rememberCredentials = true
            username = saved.username
            useKey = saved.method == .key
            if saved.method == .key {
                privateKey = saved.privateKey ?? ""
                passphrase = saved.passphrase ?? ""
                password = ""
            } else {
                password = saved.password ?? ""
                privateKey = ""
                passphrase = ""
            }
        } catch {
            NSLog("[SSH_CREDENTIALS] failed to load: %@", error.localizedDescription)
        }
    }

    private func forgetSavedCredentials() {
        do {
            try SSHCredentialStore.shared.delete(host: server.hostname)
            hasSavedCredentials = false
            rememberCredentials = false
            clearSensitiveInput()
        } catch {
            NSLog("[SSH_CREDENTIALS] failed to delete: %@", error.localizedDescription)
        }
    }

    private func savedCredential(from credentials: SSHCredentials) -> SavedSSHCredential {
        switch credentials {
        case .password(let username, let password):
            return SavedSSHCredential(
                username: username,
                method: .password,
                password: password,
                privateKey: nil,
                passphrase: nil
            )
        case .key(let username, let privateKey, let passphrase):
            return SavedSSHCredential(
                username: username,
                method: .key,
                password: nil,
                privateKey: privateKey,
                passphrase: passphrase
            )
        }
    }

    private func clearSensitiveInput() {
        password = ""
        privateKey = ""
        passphrase = ""
    }
}
