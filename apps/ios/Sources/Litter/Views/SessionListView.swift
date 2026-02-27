import SwiftUI

struct SessionListView: View {
    let server: DiscoveredServer
    let cwd: String
    var onSessionReady: ((DiscoveredServer, String) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var sessions: [ThreadSummary] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var resumingThreadId: String?
    @State private var navigateToConversation = false

    private var conn: ServerConnection? {
        serverManager.connections[server.id]
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()

            if isLoading && sessions.isEmpty {
                ProgressView().tint(LitterTheme.accent)
            } else if let err = errorMessage, sessions.isEmpty {
                VStack(spacing: 12) {
                    Text(err)
                        .font(LitterFont.monospaced(.caption))
                        .foregroundColor(.red)
                    Button("Retry") { Task { await loadSessions() } }
                        .foregroundColor(LitterTheme.accent)
                }
            } else {
                sessionList
            }
        }
        .navigationTitle(cwdLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Session") {
                    Task { await startNew() }
                }
                .foregroundColor(LitterTheme.accent)
                .font(LitterFont.monospaced(.footnote))
            }
        }
        .navigationDestination(isPresented: $navigateToConversation) {
            ConversationView()
        }
        .task { await loadSessions() }
    }

    private var cwdLabel: String {
        (cwd as NSString).lastPathComponent
    }

    private var sessionList: some View {
        List {
            if let err = errorMessage {
                Text(err)
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(.red)
                    .padding(.vertical, 6)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if sessions.isEmpty {
                VStack(spacing: 12) {
                    Text("No previous sessions")
                        .font(LitterFont.monospaced(.subheadline))
                        .foregroundColor(LitterTheme.textMuted)
                    Text("Start a new session to begin")
                        .font(LitterFont.monospaced(.caption))
                        .foregroundColor(Color(hex: "#444444"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            }

            ForEach(sessions) { session in
                Button {
                    Task { await resumeSession(session) }
                } label: {
                    sessionRow(session)
                }
                .disabled(isResuming)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if nextCursor != nil {
                Button("Load more") { Task { await loadMore() } }
                    .foregroundColor(LitterTheme.accent)
                    .font(LitterFont.monospaced(.footnote))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func sessionRow(_ session: ThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.preview.isEmpty ? "Untitled session" : session.preview)
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if resumingThreadId == session.id {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LitterTheme.accent)
                }
            }
            HStack(spacing: 8) {
                Text(relativeDate(session.updatedAt))
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(LitterTheme.textSecondary)
                Text(session.modelProvider)
                    .font(LitterFont.monospaced(.caption2))
                    .foregroundColor(LitterTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LitterTheme.accent.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func loadSessions() async {
        guard let conn else { return }
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await conn.listThreads(cwd: cwd)
            sessions = resp.data
            nextCursor = resp.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let conn, let cursor = nextCursor else { return }
        do {
            let resp = try await conn.listThreads(cwd: cwd, cursor: cursor)
            sessions.append(contentsOf: resp.data)
            nextCursor = resp.nextCursor
        } catch {}
    }

    private func resumeSession(_ session: ThreadSummary) async {
        guard !isResuming else { return }
        errorMessage = nil
        resumingThreadId = session.id
        workDir = cwd
        let success = await serverManager.resumeThread(serverId: server.id, threadId: session.id, cwd: cwd)
        resumingThreadId = nil
        if success {
            if let onSessionReady { onSessionReady(server, cwd) } else { navigateToConversation = true }
            return
        }
        if let thread = serverManager.threads[ThreadKey(serverId: server.id, threadId: session.id)],
           case .error(let message) = thread.status {
            errorMessage = message
        } else {
            errorMessage = "Failed to open conversation."
        }
    }

    private func startNew() async {
        guard !isResuming else { return }
        workDir = cwd
        let model = (serverManager.activeConnection?.models.first(where: { $0.isDefault })?.id)
        let startedKey = await serverManager.startThread(serverId: server.id, cwd: cwd, model: model)
        if startedKey != nil {
            _ = RecentDirectoryStore.shared.record(path: cwd, for: server.id)
        }
        if let onSessionReady { onSessionReady(server, cwd) } else { navigateToConversation = true }
    }

    private var isResuming: Bool {
        resumingThreadId != nil
    }
}
