import SwiftUI

/// Composer + progress overlay shown over a `SavedAppDetailView` while the
/// user asks for an update. The underlying widget remains visible (and
/// interactive) behind; the overlay dims the top portion and exposes a
/// compact progress card while the shared Rust helper regenerates HTML.
struct SavedAppUpdateOverlay: View {
    @Binding var isUpdating: Bool
    @Binding var errorMessage: String?
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var prompt: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(isUpdating ? 0.0 : 0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    guard !isUpdating else { return }
                    onDismiss()
                }

            VStack {
                Spacer()

                if isUpdating {
                    progressCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                } else {
                    composer
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            // Brief delay lets the sheet settle before grabbing focus so the
            // keyboard animation doesn't fight the overlay transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                fieldFocused = true
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Describe the change")
                    .litterFont(.subheadline, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .litterFont(size: 18)
                        .foregroundColor(LitterTheme.textMuted)
                }
            }

            TextField("e.g. make the buttons bigger", text: $prompt, axis: .vertical)
                .litterFont(size: 15)
                .focused($fieldFocused)
                .padding(12)
                .background(LitterTheme.surfaceLight.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundColor(LitterTheme.textPrimary)
                .lineLimit(1...4)

            if let errorMessage {
                Text(errorMessage)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.danger)
            }

            HStack {
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Update")
                    }
                    .litterFont(.subheadline, weight: .semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(LitterTheme.accent)
                    .foregroundColor(LitterTheme.textOnAccent)
                    .clipShape(Capsule())
                }
                .disabled(trimmedPrompt.isEmpty)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LitterTheme.surface)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 20, y: 6)
    }

    private var progressCard: some View {
        HStack(spacing: 10) {
            ProgressView().tint(LitterTheme.accent)
            Text("Working on your update…")
                .litterFont(.subheadline, weight: .medium)
                .foregroundColor(LitterTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LitterTheme.surface.opacity(0.95))
        )
        .shadow(color: Color.black.opacity(0.3), radius: 16, y: 4)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let text = trimmedPrompt
        guard !text.isEmpty else { return }
        errorMessage = nil
        onSubmit(text)
    }
}
