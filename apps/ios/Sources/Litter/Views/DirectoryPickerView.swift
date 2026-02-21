import SwiftUI

struct DirectoryPickerView: View {
    let serverId: String
    var onDirectorySelected: ((String) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @State private var currentPath = ""
    @State private var entries: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var conn: ServerConnection? {
        serverManager.connections[serverId]
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                pathBar
                Divider().background(Color(hex: "#1E1E1E"))
                content
            }
        }
        .navigationTitle("Choose Directory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { onDirectorySelected?(currentPath) }
                    .foregroundColor(LitterTheme.accent)
                    .disabled(currentPath.isEmpty)
            }
        }
        .task { await loadInitialPath() }
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(currentPath.isEmpty ? "~" : currentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().tint(LitterTheme.accent).frame(maxHeight: .infinity)
        } else if let err = errorMessage {
            VStack(spacing: 12) {
                Text(err)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await listDirectory() } }
                    .foregroundColor(LitterTheme.accent)
            }
            .frame(maxHeight: .infinity)
        } else {
            directoryList
        }
    }

    private var directoryList: some View {
        List {
            if currentPath != "/" {
                Button {
                    Task { await navigateUp() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.up.left")
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(width: 20)
                        Text("..")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            ForEach(entries, id: \.self) { entry in
                Button {
                    Task { await navigateInto(entry) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(LitterTheme.accent)
                            .frame(width: 20)
                        Text(entry)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(LitterTheme.textMuted)
                            .font(.caption)
                    }
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Actions

    private func loadInitialPath() async {
        if currentPath.isEmpty {
            currentPath = await resolveHome()
        }
        await listDirectory()
    }

    private func resolveHome() async -> String {
        if conn?.server.source == .local {
            return NSHomeDirectory()
        }
        guard let conn else { return "/" }
        do {
            let resp = try await conn.execCommand(
                ["/bin/sh", "-lc", "printf %s \"$HOME\""],
                cwd: "/tmp"
            )
            if resp.exitCode == 0 {
                let home = resp.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !home.isEmpty { return home }
            }
        } catch {}
        return "/"
    }

    private func listDirectory() async {
        guard let conn else { return }
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await conn.execCommand(
                ["/bin/ls", "-1ap", currentPath],
                cwd: currentPath
            )
            if resp.exitCode != 0 {
                errorMessage = resp.stderr.isEmpty ? "ls failed with code \(resp.exitCode)" : resp.stderr
                isLoading = false
                return
            }
            let lines = resp.stdout.split(separator: "\n").map(String.init)
            let dirs = lines.filter { $0.hasSuffix("/") && $0 != "./" && $0 != "../" }
            entries = dirs.map { String($0.dropLast()) }.sorted()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func navigateInto(_ name: String) async {
        if currentPath.hasSuffix("/") {
            currentPath += name
        } else {
            currentPath += "/\(name)"
        }
        await listDirectory()
    }

    private func navigateUp() async {
        currentPath = (currentPath as NSString).deletingLastPathComponent
        await listDirectory()
    }
}
