import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                BrandLogo(size: 112)
                Text("Open the sidebar to start a session")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
                if !serverManager.hasAnyConnection {
                    Button("Connect to Server") {
                        appState.showServerPicker = true
                    }
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(LitterTheme.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(LitterTheme.accent.opacity(0.4), lineWidth: 1)
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
