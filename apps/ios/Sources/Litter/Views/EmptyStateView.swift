import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState

    private var connectedServerNames: [String] {
        serverManager.connections.values
            .filter { $0.isConnected }
            .map { $0.server.name }
            .sorted()
    }

    private var connectionSummary: String {
        guard let first = connectedServerNames.first else { return "Not connected" }
        let extraCount = connectedServerNames.count - 1
        if extraCount <= 0 {
            return "Connected: \(first)"
        }
        return "Connected: \(first) +\(extraCount)"
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                BrandLogo(size: 112)
                Text("Open the sidebar to start a session")
                    .font(LitterFont.monospaced(.body))
                    .foregroundColor(LitterTheme.textMuted)
                if !connectedServerNames.isEmpty {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(LitterTheme.accent)
                            .frame(width: 8, height: 8)
                        Text(connectionSummary)
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(LitterTheme.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                if !serverManager.hasAnyConnection {
                    Button("Connect to Server") {
                        appState.showServerPicker = true
                    }
                    .font(LitterFont.monospaced(.body))
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
