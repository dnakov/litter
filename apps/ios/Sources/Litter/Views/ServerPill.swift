import SwiftUI

struct ServerPill: View {
    let server: HomeDashboardServer
    let isSelected: Bool
    let onTap: () -> Void
    let onReconnect: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                StatusDot(state: server.statusDotState, size: 8)
                Text(server.displayName)
                    .litterMonoFont(size: 13, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    isSelected ? LitterTheme.accent.opacity(0.75) : LitterTheme.textMuted.opacity(0.25),
                    lineWidth: isSelected ? 1.2 : 0.6
                )
                .allowsHitTesting(false)
        )
        .contextMenu {
            Button {
                onReconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            if !server.isLocal {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

struct AddServerPill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("server")
                    .litterMonoFont(size: 13, weight: .semibold)
            }
            .foregroundStyle(LitterTheme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.accent.opacity(0.45), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
    }
}
