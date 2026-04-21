import SwiftUI

/// Minimal reply composer shown when the user swipes right on a home
/// session row. Sends a turn on the targeted thread and dismisses.
struct QuickReplySheet: View {
    let thread: HomeDashboardRecentSession
    let onSend: @MainActor (ThreadKey, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(thread.sessionTitle)
                    .litterFont(.subheadline, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(2)

                Text(thread.serverDisplayName + " · " + (HomeDashboardSupport.workspaceLabel(for: thread.cwd) ?? thread.cwd))
                    .litterFont(.caption)
                    .foregroundStyle(LitterTheme.textMuted)
                    .lineLimit(1)

                Divider().background(LitterTheme.separator)

                TextField(
                    "Reply…",
                    text: $text,
                    axis: .vertical
                )
                .focused($isFocused)
                .lineLimit(1...8)
                .submitLabel(.send)
                .litterFont(.body)
                .foregroundStyle(LitterTheme.textPrimary)
                .padding(10)
                .background(LitterTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(LitterTheme.border, lineWidth: 0.5)
                )

                if let errorMessage {
                    Text(errorMessage)
                        .litterFont(.caption)
                        .foregroundStyle(LitterTheme.danger)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 6) {
                            if isSending {
                                ProgressView().controlSize(.small).tint(.black)
                            }
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Send")
                                .litterFont(.subheadline, weight: .semibold)
                        }
                        .foregroundStyle(canSend ? Color.black : LitterTheme.textMuted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(canSend ? LitterTheme.accent : LitterTheme.surfaceLight, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }

                Spacer()
            }
            .padding(16)
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .tint(LitterTheme.textSecondary)
                }
            }
            .task {
                // Pop the keyboard once the sheet has settled.
                try? await Task.sleep(nanoseconds: 150_000_000)
                isFocused = true
            }
        }
    }

    private func submit() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        await onSend(thread.key, trimmed)
        isSending = false
        dismiss()
    }
}
