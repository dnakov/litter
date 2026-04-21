import SwiftUI

struct ProjectChip: View {
    let project: AppProject?
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(project != nil ? LitterTheme.accent : LitterTheme.textMuted)
                Text(label)
                    .litterMonoFont(size: 12, weight: .semibold)
                    .foregroundStyle(project != nil ? LitterTheme.textPrimary : LitterTheme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitterTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.textMuted.opacity(0.55), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private var label: String {
        if let project {
            return projectDefaultLabel(cwd: project.cwd)
        }
        return disabled ? "no server" : "pick project"
    }
}
