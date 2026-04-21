import SwiftUI
import UIKit

struct ConversationComposerExpandedView: View {
    @Binding var inputText: String
    @Binding var isPresented: Bool
    let onPasteImage: (UIImage) -> Void
    let onSend: () -> Void
    let hasAttachment: Bool

    // Start unfocused so the `.task` below forces a false→true transition,
    // which is what drives `ConversationComposerTextView`'s coordinator to
    // call `becomeFirstResponder` once the UITextView is attached to a
    // window. Starting at `true` can no-op if the view hasn't finished the
    // fullScreenCover transition by the time `syncFocus` runs.
    @State private var isFocused = false

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty || hasAttachment
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                ConversationComposerTextView(
                    text: $inputText,
                    isFocused: $isFocused,
                    onPasteImage: onPasteImage,
                    unboundedHeight: true
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if inputText.isEmpty {
                    Text("Message litter...")
                        .font(LitterFont.styled(size: 17))
                        .foregroundColor(LitterTheme.textMuted)
                        .padding(.leading, 24)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(LitterFont.styled(size: 15, weight: .semibold))
                            .foregroundColor(LitterTheme.textPrimary)
                    }
                    .accessibilityLabel("Collapse composer")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSend()
                        isPresented = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(canSend ? LitterTheme.accent : LitterTheme.textMuted)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            .task {
                // Small delay lets the cover finish its transition and the
                // UITextView attach to a window, so becomeFirstResponder sticks.
                try? await Task.sleep(nanoseconds: 150_000_000)
                isFocused = true
            }
        }
    }
}
