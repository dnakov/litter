import SwiftUI

struct ServerPickerView: View {
    let servers: [DirectoryPickerServerOption]
    let selectedServerId: String
    var onSelect: (DirectoryPickerServerOption) -> Void
    var onDismiss: () -> Void

    @State private var searchQuery = ""

    private var filteredServers: [DirectoryPickerServerOption] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return servers }
        return servers.filter { server in
            server.name.localizedCaseInsensitiveContains(query) ||
                server.backendLabel.localizedCaseInsensitiveContains(query) ||
                server.sourceLabel.localizedCaseInsensitiveContains(query) ||
                server.subtitle.localizedCaseInsensitiveContains(query) ||
                (server.lastUsedDirectoryHint?.localizedCaseInsensitiveContains(query) == true) ||
                (server.defaultModelLabel?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick Server")
                        .litterFont(size: 18, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text("Choose a backend first. Workspace selection comes next.")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(LitterTheme.textMuted)
                    TextField("Search servers", text: $searchQuery)
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(LitterTheme.surface.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
                )
                .cornerRadius(8)

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredServers) { server in
                            serverRow(server)
                        }
                    }
                }

                Button("Cancel", action: onDismiss)
                    .buttonStyle(.plain)
                    .litterFont(.subheadline)
                    .foregroundColor(LitterTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LitterTheme.surface.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
                    )
                    .cornerRadius(8)
            }
            .padding(16)
        }
        .navigationTitle("Pick Server")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serverRow(_ server: DirectoryPickerServerOption) -> some View {
        Button {
            onSelect(server)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(LitterTheme.accent)
                        .frame(width: 8, height: 8)
                    Text(server.name)
                        .litterFont(.subheadline, weight: .medium)
                        .foregroundColor(LitterTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if server.id == selectedServerId {
                        Text("Current")
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textOnAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LitterTheme.accent)
                            .cornerRadius(4)
                    }
                }

                Text(server.subtitle)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    summaryChip(server.backendLabel, color: LitterTheme.accent)
                    summaryChip(server.sourceLabel, color: LitterTheme.textSecondary)
                    summaryChip(server.statusLabel, color: LitterTheme.textSecondary)
                }

                if let directory = server.lastUsedDirectoryHint, !directory.isEmpty {
                    Text(directory)
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textMuted)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(server.defaultModelLabel.map { "Default model: \($0)" } ?? server.modelCatalogCountLabel)
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(server.backendKind == .openCode ? "\(server.knownDirectories.count) scopes" : (server.canBrowseDirectories ? "Browse" : "Select"))
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LitterTheme.surface.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func summaryChip(_ label: String, color: Color) -> some View {
        Text(label)
            .litterFont(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }
}

